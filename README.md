# GPU-Aware Autoscaler for LLM Inference on Kubernetes

> **Status: Work in Progress** — Phase 0 (foundation) is partly scaffolded. GPU node pool, KEDA scaler chart, load tests, and SigNoz dashboards are under active development. See [Roadmap](#roadmap).

A production-style Kubernetes autoscaler for LLM inference. The clever bit isn't the autoscaler itself — it's *what it scales on*. Standard HPA reads CPU and memory, both of which are blind to GPU saturation on a vLLM pod. This project replaces them with **KV cache pressure** and **request queue depth** — the signals that actually predict latency.

Built around vLLM + KEDA + Prometheus + SigNoz on GKE Standard with NVIDIA L4 spot nodes.

## Motivation

Most Kubernetes tutorials for LLM serving either use CPU-based HPA (the wrong metric) or skip autoscaling entirely. This project answers:

- **What's the right scaling signal for LLM serving?** Why do CPU and memory miss the boat, and what does vLLM expose that's actually predictive of user-facing latency?
- **How do you get an *early warning* before TTFT spikes?** The difference between leading and lagging indicators in a system where pods take 30+ seconds to come up.
- **How do you scale a stateful inference service?** Cold-start latency, model loading, replica warmup — none of these are problems an HPA tutorial covers.
- **How do you tune cooldown without thrashing?** Spot GPUs get preempted on a daily-ish cadence; the autoscaler has to be patient.
- **How do you observe a fleet of inference pods?** TTFT distributions, queue depth over time, replica count correlated with traffic — all in one dashboard.

## Demo

<!-- TODO: Record demo videos and link them here -->

### Walkthrough script (what to show in order)

1. **Idle cluster** — 0 vLLM pods, 0 GPU nodes. Hourly cost: ₹0.
2. **Steady traffic** — Locust ramps to 5 RPS. KEDA spins up 1 vLLM pod. The cluster autoscaler provisions a fresh L4 spot node.
3. **Burst** — Locust spikes to 50 RPS. Watch `vllm:gpu_cache_usage_perc` cross 85% *before* the request queue starts building.
4. **Scale up** — KEDA detects the leading indicator and scales to 3 pods over ~90 seconds.
5. **TTFT stays flat** — SigNoz dashboard shows p99 TTFT didn't spike during the burst. That's the whole point — we scaled before users felt pain.
6. **Scale down** — Locust quiets, KEDA scales back to 0 after the cooldown, GPU node drains and is reclaimed.
7. **Cost summary** — total spend for the demo: under ₹150 (~$2 USD).

## How it works

```
                    ┌──────────────┐
                    │   Locust     │  Bursty inference traffic
                    │  Load Test   │  (Hindi/English prompts, variable lengths)
                    └──────┬───────┘
                           │
                           ▼
┌─────────────────────────────────────────────────┐
│                  GKE Cluster                     │
│  ┌────────┐    ┌────────┐    ┌────────┐         │
│  │ vLLM   │    │ vLLM   │    │ vLLM   │  ◄──┐  │
│  │ Pod 1  │    │ Pod 2  │    │ Pod N  │     │  │
│  │ (L4)   │    │ (L4)   │    │ (L4)   │     │  │
│  └───┬────┘    └───┬────┘    └───┬────┘     │  │
│      │             │             │           │  │
│      └─────────┬───┴─────────────┘           │  │
│                │ /metrics                     │  │
│                ▼                              │  │
│  ┌──────────────────┐    ┌──────────────┐    │  │
│  │   Prometheus      │───▶│    KEDA      │────┘  │
│  │ (scrapes metrics) │    │ (autoscaler) │       │
│  └────────┬─────────┘    └──────────────┘       │
│           │                                      │
│           ▼                                      │
│  ┌──────────────────┐                            │
│  │     SigNoz       │  Dashboards & alerting     │
│  └──────────────────┘                            │
└─────────────────────────────────────────────────┘
```

### The metric story

KEDA watches these vLLM Prometheus metrics, not CPU/memory:

| Metric | What it is | Why it matters |
|---|---|---|
| `vllm:num_requests_waiting` | Requests queued because all KV cache slots are taken | **Lagging indicator.** If this is non-zero, you're already late — but it's the most direct "we're under-provisioned" signal. |
| `vllm:gpu_cache_usage_perc` | Fraction of KV cache memory in use | **Leading indicator.** When this hits ~85%, TTFT begins spiking *before* the queue builds. This is what gives the autoscaler early warning. |
| `vllm:e2e_request_latency_seconds` (TTFT histogram) | End-to-end and TTFT distributions | The actual user-facing metric we're protecting. SigNoz dashboards plot p50/p95/p99. |
| `vllm:tokens_per_second` (derived) | Throughput per pod | Detects saturation when the queue is temporarily empty but the GPU is fully loaded. |

The key insight: **using both the leading and the lagging indicator together gives responsive autoscaling**. The leading indicator scales us up before users feel pain; the lagging one is a safety net for traffic shapes the leading indicator misses.

## Companion project

This is the **serving and autoscaling** side of an end-to-end MLOps story. The **training, experiment tracking, model registry, and GitOps deployment** side lives in [`customer_churn_CICD`](https://github.com/my-neme-eh-jeff/customer_churn_CICD) (DVC + MLflow + Kubeflow Pipelines + ArgoCD on GKE Autopilot, plus an LLM-driven autonomous research loop). Together they cover the full lifecycle:

| Concern | Project |
|---|---|
| Reproducible data + experiments | customer_churn (DVC + MLflow) |
| Model registry, champion/challenger | customer_churn (MLflow registry) |
| Continuous training + auto-research | customer_churn (Kubeflow Pipelines + auto-loop) |
| GitOps deployment of model artifacts | customer_churn (ArgoCD) |
| **GPU-aware inference serving** | **autoscaler (this repo)** |
| **LLM-native autoscaling** | **autoscaler (this repo)** |
| **Inference observability (TTFT, KV cache, queue depth)** | **autoscaler (this repo)** |

## Tech Stack

| Component | Technology | Why |
|-----------|-----------|-----|
| Model serving | [vLLM](https://docs.vllm.ai) | PagedAttention for efficient KV cache management; native Prometheus metrics; the 2026 production default per [Hao AI Lab retrospective](https://haoailab.com/blogs/distserve-retro/) |
| Autoscaler | [KEDA](https://keda.sh) | Event-driven scaling on custom Prometheus queries — standard HPA can't query custom metrics natively without an external adapter |
| Metrics | [Prometheus](https://prometheus.io) | Scrapes vLLM `/metrics`, feeds KEDA scaling decisions via the `prometheus` scaler |
| Observability | [SigNoz](https://signoz.io) | OpenTelemetry-native, single-pane-of-glass for traces + metrics + logs |
| Load testing | [Locust](https://locust.io) | Scriptable bursty traffic patterns in plain Python |
| Infrastructure | Terraform + GKE Standard | GKE Standard is required for fine-grained GPU node-pool control (Autopilot abstracts that away) |
| Packaging | Helm | Multiple parameterized environments (vind dev, GKE GPU prod) — too much variance for raw YAML |
| Local dev | [vind](https://github.com/loft-sh/vind) | vCluster in Docker — native LoadBalancer, pause/resume |
| GPU model (dev) | `Qwen/Qwen2.5-0.5B-Instruct` | Tiny, runs on CPU for vind / RTX 2060 |
| GPU model (prod demo) | `Qwen/Qwen3-8B-Instruct-AWQ` | Popular 2026 open model from Alibaba; fits on a single L4 (24GB VRAM) with KV cache headroom; demonstrably saturable under bursty load |

## Repository Structure

```
autoscaler/
├── README.md                  # This file
├── CLAUDE.md                  # Dev context for Claude Code
├── EXPLANATION.md             # Deep technical walkthrough (the "why" of every decision)
├── Makefile                   # All dev commands
├── pyproject.toml             # uv-managed Python deps for load-test + scripts
│
├── gcp/                       # Terraform IaC
│   ├── main.tf                # GKE Standard cluster + VPC + networking
│   ├── gpu-pool.tf            # L4 spot node pool (taints, autoscale 0→3)
│   ├── variables.tf
│   ├── providers.tf
│   ├── terraform.tfvars       # gitignored — project-specific
│   └── README.md
│
├── helm/
│   ├── vllm-server/           # vLLM Deployment + Service + ServiceMonitor
│   │   ├── values.yaml          # default: GPU production (L4 + Mistral-7B AWQ)
│   │   ├── values-cpu-dev.yaml  # vind override: opt-125m on CPU
│   │   └── templates/
│   └── keda-scaler/           # KEDA ScaledObject (KV cache + queue depth triggers)
│       ├── values.yaml
│       └── templates/
│           └── scaledobject.yaml
│
├── monitoring/
│   ├── prometheus/            # kube-prometheus-stack values + recording rules
│   └── signoz/                # SigNoz Helm values + dashboards (importable JSON)
│
├── load-test/                 # Locust scripts
│   ├── locustfile.py
│   ├── prompts.py             # Realistic Indian-language prompt corpus
│   └── scenarios/             # steady / burst / soak
│
├── vind/                      # Local vCluster config
│
└── scripts/                   # One-off helpers (bootstrap, port-forward, verify)
```

## Quick Start

### Prerequisites

- A GCP project with a paid billing account (free-trial credits are fine and apply to GPU spend after upgrade — see [Cost transparency](#cost-transparency))
- L4 GPU quota approved in your target region (default: `asia-south1`)
- Tools: `gcloud`, `terraform` (>=1.6), `kubectl` (>=1.30), `helm` (>=3), `uv` (Python)

### Provision GKE + GPU pool

```bash
cd gcp/
cp terraform.tfvars.example terraform.tfvars   # then fill in your project ID
terraform init
terraform plan
terraform apply       # ~8-10 minutes for cluster + node pool

gcloud container clusters get-credentials autoscaler-gke \
  --region asia-south1 --project <your-project-id>
```

### Install the stack

```bash
make install-keda
make install-prometheus
make install-signoz
make install-vllm
make install-keda-scaler

make metrics          # verify vLLM /metrics is being scraped
```

### Run a load test

```bash
make load-test        # 5 minutes of bursty traffic, watch SigNoz
```

### Tear down (avoid surprise spend)

```bash
make tear-down        # uninstall charts
cd gcp/ && terraform destroy
```

### Local dev (no GPU, vind)

```bash
make cluster-up               # spawn local vind cluster
make install-vllm-cpu-dev     # opt-125m on CPU
make load-test                # works against local cluster too
make cluster-pause            # save laptop battery between sessions
```

## Cost transparency

This project is built to run on GCP free-trial credits *after* upgrading the billing account to "Paid account" status (which unlocks GPUs). All GPU spend draws from the trial credit pool until exhausted; only then does the attached card get charged.

| Component | Hourly cost (approx) |
|---|---|
| GKE Standard control plane | ~$0.10 |
| 1× L4 spot node (`g2-standard-8`) | ~$0.30 |
| 100GB pd-balanced disk | ~$0.04 |
| Prometheus + SigNoz on `n2-standard-2` (always-on) | ~$0.10 |

**Realistic project spend with KEDA scale-to-zero + 1-hour daily demo cadence: $20-50 across 2-3 months.** The whole project sits comfortably inside the standard $300 trial credit. (See `EXPLANATION.md` and `docs/COST.md` for a line-item breakdown after the demo runs.)

The cluster is designed to be spun up for demo runs and torn down between sessions. `make tear-down && terraform destroy` brings hourly cost to ~$0.

## Honest limitations

- **Single zone.** `asia-south1-a` only — no HA. A zone outage takes the demo down.
- **Single GPU type.** Built and tested only on L4. T4 should work but is too small for credible KV-cache-pressure demos with a 7B model. A100 works but burns trial credit fast.
- **Spot preemption.** L4 spot can be reclaimed in 30 seconds with no warning. KEDA cooldown absorbs this in normal operation, but during a *recorded* demo, switch the node pool to on-demand briefly to avoid mid-recording preemption.
- **Demo-grade observability.** SigNoz runs single-replica with reduced retention. A production deployment would need ClickHouse HA + ≥30-day retention.
- **Synthetic load.** Locust patterns are bursty but synthetic. Real Sarvam-style traffic mixes much higher prompt-length variance, multi-turn agent loops, and per-tenant patterns.
- **No PD-disaggregation, no multi-LoRA, no speculative decoding** in Phase 0. Those are explicit follow-on phases — see [Roadmap](#roadmap).

## Known infra quirks

- **vLLM readiness probe needs ≥30s for cold start.** A 7B AWQ model loads in ~25-40s on L4. Default probes (10s initial + 1s period + 3 failures) kill the pod before the model finishes loading.
- **ServiceMonitor must be labeled `release: prometheus`.** kube-prometheus-stack's `serviceMonitorSelector` defaults to that label. Without it, Prometheus silently doesn't scrape — no error, just an empty target list.
- **AWQ models on vLLM need explicit `--quantization awq`.** vLLM doesn't auto-detect from the model card; pass it as a server flag.
- **L4 spot preemption is roughly daily** with ~30s drain notice. KEDA's 300s cooldown absorbs this in normal operation, but switch to on-demand briefly when recording demos.

## GitOps and packaging — why Helm here, raw YAML in customer_churn

[customer_churn](https://github.com/my-neme-eh-jeff/customer_churn_CICD) deliberately uses raw YAML manifests + ArgoCD because it has 4 manifests, one environment, and no templating need. This project uses Helm because it has *three* deployment shapes:

- vind local dev (CPU model, no GPU node pool, debug logging)
- GKE GPU production (L4 + AWQ model + tolerations + nodeSelector)
- Future llm-d / disaggregated layout (Phase 4)

That's enough variance that Helm's `values.yaml` + per-environment overrides pay for themselves — without templating, you'd be maintaining three near-duplicate copies of every manifest.

This is a deliberate engineering judgment, not a stylistic flip. Both projects are correct for their scale.

## Tools and Why

| Tool | Role | Why |
|------|------|-----|
| **vLLM** | LLM serving engine | PagedAttention; OpenAI-compatible API; native Prometheus metrics; the 2026 production default |
| **KEDA** | Event-driven autoscaler | The only K8s autoscaler that natively supports Prometheus queries as scaling triggers |
| **Prometheus** | Metrics backend | Standard. ServiceMonitor + kube-prometheus-stack is the K8s default |
| **SigNoz** | Observability platform | OpenTelemetry-native, single platform for traces + metrics + logs, great UX for TTFT histograms |
| **Locust** | Load tester | Python-native bursty patterns; Hindi/English prompt corpora easy to express in plain code |
| **Terraform** | Infra-as-code | Reproducible cluster, parameterized via tfvars, swap-friendly to AKS/EKS in principle |
| **GKE Standard** | Managed Kubernetes | Required for per-node-pool GPU configuration; Autopilot abstracts that away |
| **Helm** | Manifest packaging | Multi-environment (vind dev / GKE GPU prod / future llm-d) with values overrides |
| **vind** | Local Kubernetes | Native LoadBalancer; pause/resume saves laptop battery between sessions |
| **uv** | Python package manager | Fast, replaces pip/poetry/pyenv |

## Roadmap

### Phase 0 — Foundation (in progress)
- [x] Repo scaffold
- [x] Helm chart skeleton for vLLM (Deployment, Service, ServiceMonitor)
- [x] Terraform IaC for GKE Standard cluster (CPU-only base pool)
- [x] kube-prometheus-stack values
- [x] SigNoz values
- [x] vind local config
- [ ] L4 spot GPU node pool in Terraform
- [ ] vLLM Helm values for GPU production (Mistral-7B-Instruct AWQ)
- [ ] KEDA ScaledObject Helm chart (KV cache + queue depth triggers)
- [ ] Locust load-test scripts (steady / burst / soak)
- [ ] Prometheus recording rules for derived metrics
- [ ] SigNoz dashboards (TTFT distribution, KV cache, replica count, autoscaler events)
- [ ] End-to-end demo recorded

### Phase 1 — Multi-LoRA serving
A single vLLM base model + 10 LoRA adapters, routed by request header. Per-tenant rate limiting via Redis. The pattern Sarvam asks about in MLOps JDs ([Punica/S-LoRA](https://github.com/punica-ai/punica)).

### Phase 2 — Quantization comparison harness
Benchmark FP16 / FP8 / AWQ-INT4 on a 7B model: accuracy (MMLU-Pro, HumanEval+), throughput, TTFT, VRAM. Blog-shaped writeup.

### Phase 3 — EAGLE-3 speculative decoding
Deploy [EAGLE-3](https://github.com/SafeAILab/EAGLE) with vLLM, measure 2× decode speedup, full latency + quality eval. The 2026 ML-Engineer-signal project.

### Phase 4 — PD-disaggregated autoscaler with llm-d
Extend Phase 0 into the headline 2026 architecture: separate prefill and decode pools, scale each independently with KEDA, KV-cache-aware routing via [llm-d](https://llm-d.ai).

## Why this matters

If you're hiring for an MLOps Engineer or ML Engineer (Inference) role at an Indian AI startup like Sarvam, Krutrim, or Yotta — the JDs explicitly ask for vLLM, Triton, GGUF/AWQ/GPTQ quantization, Kubernetes, Prometheus/Grafana. This project hits five of those bullets with one demo. Phases 1-3 hit the rest.

For interviewers: the demo runs in 5 minutes, costs less than ₹150, and produces a single dashboard view that shows the autoscaler responding to KV-cache pressure 30 seconds before the request queue builds — the difference between an "I read the vLLM blog" portfolio and an "I have run this in production" portfolio.

## License

MIT
