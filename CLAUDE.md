# Autoscaler Project — CLAUDE.md

## What this project is

A GPU-aware Kubernetes autoscaler for LLM inference, purpose-built as a portfolio project targeting **Sarvam AI** and similar Indian AI/ML startups. The goal is for Aman to present as an **MLOps / ML Infrastructure engineer** — someone who understands both the Kubernetes/SRE layer and the LLM inference internals.

The core insight the project demonstrates: standard HPA is blind to GPU saturation. A vLLM pod at 20% CPU can be completely saturated if its KV cache is full. This project autoscales on LLM-native signals instead.

---

## Goals and non-goals

**Goals**
- Production-quality, well-documented code that can be shown in interviews
- Demonstrate understanding of WHY each component exists, not just that it works
- Every design decision should be explainable in terms of LLM inference behavior (KV cache, TTFT, throughput)
- Deployable on Azure or AWS (cloud-agnostic Helm charts)

**Non-goals**
- Training or fine-tuning models (Raju owns model selection/setup)
- Supporting CPU-only inference as a production target
- Over-engineering: no abstractions that aren't needed right now

---

## Ownership split

| Area | Owner |
|---|---|
| Model selection, training/setup | Raju |
| SigNoz observability setup | Aman |
| KEDA autoscaling setup | Aman |
| CI/CD pipeline | Aman + Raju together |

---

## Tech stack (locked)

| Component | Technology |
|---|---|
| Model serving | vLLM |
| Autoscaler | KEDA with Prometheus external scaler |
| Metrics backend | Prometheus (scraped from vLLM `/metrics`) |
| Observability / dashboards | SigNoz |
| Load testing | Locust |
| Deployment packaging | Helm charts |
| Local K8s | vind (vCluster in Docker) — see section below |
| Cloud | Azure or AWS only |
| Model (dev) | `facebook/opt-125m` or similar small model |
| Model (prod target) | Sarvam-M (on Hugging Face) |

---

## Key LLM metrics we care about (and why)

These are the autoscaling signals — always explain them in terms of inference behavior:

- **`vllm:num_requests_waiting`** — requests queued because all KV cache slots are occupied. The most direct signal for "we need more pods".
- **`vllm:gpu_cache_usage_perc`** — fraction of KV cache in use. When this hits ~85%, TTFT starts spiking before the queue even builds.
- **TTFT (time-to-first-token)** — the latency a user feels before streaming starts. Derived metric, computed from vLLM request logs.
- **Tokens/sec throughput** — overall serving capacity. Used to detect when a pod is near saturation even if queue is temporarily empty.

Standard HPA signals (CPU, memory) are explicitly NOT used — include a comment explaining why wherever HPA config appears.

---

## Repo structure

```
autoscaler/
├── helm/
│   ├── vllm-server/        # Helm chart for vLLM Deployment + Service + ServiceMonitor
│   └── keda-scaler/        # KEDA ScaledObject + HPA override config
├── keda-scaler/            # Custom KEDA external scaler (Go or Python)
├── load-test/              # Locust load test scripts (bursty Indian-language traffic patterns)
├── monitoring/
│   ├── prometheus/         # Scrape configs, recording rules
│   └── signoz/             # Dashboard JSON, alert rules
├── vind/                   # vind cluster config (vcluster.yaml)
├── Makefile                # Common dev commands
└── CLAUDE.md
```

---

## Code style and conventions

- **Helm charts**: values.yaml must have comments explaining every non-obvious field. No magic numbers.
- **Kubernetes manifests**: always include resource requests/limits. For GPU workloads, `nvidia.com/gpu: 1` in limits.
- **KEDA ScaledObject**: `pollingInterval`, `cooldownPeriod`, `minReplicaCount`, `maxReplicaCount` must all be tunable via values.yaml — never hardcoded.
- **Python**: use `uv` for dependency management. Type hints on all function signatures.
- **Go** (if used for scaler): standard project layout, no global state.
- **Makefile targets**: `make up`, `make down`, `make load-test`, `make metrics` at minimum.
- Comments should explain **why**, not what. The code shows what.

---

## How to explain this project in interviews

When asked "walk me through this project", the answer should flow:

1. **Problem**: Sarvam-style bursty inference traffic. HPA doesn't understand KV cache saturation.
2. **Solution**: KEDA ScaledObject watching `vllm:num_requests_waiting` and `vllm:gpu_cache_usage_perc` via Prometheus.
3. **Why those metrics**: KV cache fills → requests queue → TTFT spikes. The cache metric gives early warning before the queue builds (leading indicator vs lagging indicator).
4. **Deployment**: Helm charts, cloud-agnostic, tested on kind locally, targets AKS/EKS in prod.
5. **Observability**: SigNoz dashboards showing TTFT distribution, queue depth over time, replica count changes correlated with traffic.

---

## vind — Local Kubernetes setup

We use **vind** (vCluster in Docker) instead of kind for local development.

- Blog deep-dive: https://www.vcluster.com/blog/replacing-kind-with-vind-deep-dive
- GitHub repo: https://github.com/loft-sh/vind
- Docs: https://vcluster.com/docs

### Why vind over kind

| | kind | vind |
|---|---|---|
| LoadBalancer support | manual plugin (MetalLB) | built-in, automatic |
| Pause/resume cluster | must delete and recreate | `vcluster pause` / `vcluster resume` |
| UI | CLI only | built-in vCluster Platform web UI |
| External nodes | local only | attach cloud VMs via VPN overlay |
| Image caching | no | pull-through cache via Docker |

For this project the killer feature is **native LoadBalancer support** — vLLM and Prometheus need to be reachable from localhost without extra MetalLB setup.

### Requirements

- Docker (running)
- vCluster CLI v0.31.0+

### Setup

```bash
vcluster upgrade --version v0.31.0
vcluster use driver docker       # switch to Docker driver (enables vind mode)
vcluster platform start          # optional: start the web UI BEFORE creating cluster
vcluster create autoscaler-dev   # create the local cluster
```

### Common commands

```bash
vcluster list                        # show all clusters
vcluster pause autoscaler-dev        # suspend (saves resources)
vcluster resume autoscaler-dev       # wake up
vcluster delete autoscaler-dev       # tear down
docker exec vcluster.cp.autoscaler-dev journalctl -u vcluster  # control plane logs
```

### Config file

Cluster config lives in `vind/vcluster.yaml`. Key things to configure there:
- custom Docker network
- port forwards (e.g. vLLM 8000, Prometheus 9090, SigNoz 3301)
- any extra node args

---

## Development phases

- **Phase 1** (current): Local kind cluster + vLLM (small model) + Prometheus scraping metrics
- **Phase 2**: KEDA ScaledObject wired to Prometheus metrics, basic scaling working
- **Phase 3**: SigNoz dashboards, Locust load tests, tuning cooldown/threshold values
- **Phase 4**: Helm charts cleaned up, cloud deployment guide (AKS or EKS), README for portfolio
