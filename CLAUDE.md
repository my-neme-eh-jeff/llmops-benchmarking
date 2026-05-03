# Autoscaler — GPU-Aware LLM Inference Autoscaler

## Project overview

GPU-aware Kubernetes autoscaler for LLM inference, built around vLLM + KEDA + Prometheus + SigNoz on GKE. Replaces CPU-based HPA with autoscaling on **KV cache pressure** and **request queue depth** — the signals that actually predict TTFT under load.

The serving + autoscaling companion to [`customer_churn_CICD`](https://github.com/my-neme-eh-jeff/customer_churn_CICD), which covers training / registry / GitOps. Together they form an end-to-end MLOps story.

**Owner:** Aman — targeting MLOps Engineer + ML Engineer (Inference) roles, with explicit focus on Indian AI startups (Sarvam, Krutrim, Yotta). This is a portfolio + learning project.

**Collaboration style:** Do NOT just build things silently. Aman wants to learn each concept deeply — explain the "why," share industry examples, ask questions to check understanding, share blog posts. Teach end-to-end before and after implementing. Pair-programming with a teaching component.

## Tech stack

| Tool | Version | Purpose |
|------|---------|---------|
| Python | 3.12 | Load test + helper scripts runtime |
| uv | latest | Package manager (**never use pip**) |
| Terraform | 1.6+ | GCP IaC |
| Helm | 3.14+ | K8s manifest packaging |
| kubectl | 1.30+ | Cluster control |
| vLLM | 0.6.3+ | LLM serving engine |
| KEDA | 2.15+ | Event-driven autoscaler |
| kube-prometheus-stack | 60+ | Prometheus + Operator |
| SigNoz | 0.55+ | Observability (traces + metrics + logs) |
| Locust | 2.31+ | Load testing |
| vind (vcluster) | 0.31+ | Local Kubernetes (**never use kind**) |
| ruff | 0.6+ | Lint + format |

## Commands

```bash
# Cluster lifecycle (local vind)
make cluster-up         # Create local vind cluster
make cluster-down       # Delete local vind cluster
make cluster-pause      # Suspend (save laptop battery)
make cluster-resume     # Wake suspended cluster

# Stack installation (works on local + GKE)
make install-keda       # Install KEDA via Helm
make install-prometheus # Install kube-prometheus-stack
make install-signoz     # Install SigNoz
make install-vllm       # Install vLLM (default: GPU prod values)
make install-vllm-cpu-dev   # vind override: opt-125m on CPU
make install-keda-scaler    # Install KEDA ScaledObject

# Dev helpers
make metrics            # Curl vLLM /metrics, grep vllm: lines
make signoz-ui          # Port-forward SigNoz to localhost:8080
make load-test          # Run Locust bursty pattern (5 min)
make tear-down          # Uninstall all charts (keeps cluster up)
```

## Architecture (what's actually running)

### GKE deployment (production demo)

**GCP Project:** `project-8018ed81-1dfe-470e-aad` — **same project as customer_churn**. The autoscaler runs in its own namespaces (`vllm`, `keda`, `platform`) on a separate GKE cluster. Quota and credits are billing-account-scoped, so a new project would not give us extra quota; one project keeps `gcloud` ergonomics simple.
**Billing account:** `01411E-7B7536-664426` (Paid account, free-trial credit ~₹27,603 remaining as of 2026-05-03)
**Cluster:** `autoscaler-gke` — GKE Standard, `asia-south1`, single zone (`asia-south1-a`). Distinct from customer_churn's `mlops-cluster` (Autopilot).

| Namespace | Service | Public URL |
|-----------|---------|-----------|
| `vllm` | vLLM server (0–3 replicas, KEDA-managed) | LoadBalancer IP — TBD after first apply |
| `monitoring` | Prometheus + Grafana (Grafana disabled) | ClusterIP only |
| `platform` | SigNoz UI | TBD after first apply |
| `keda` | KEDA operator | n/a |

> **Note:** Same GCP project as `customer_churn_CICD`. Two clusters live side by side: `mlops-cluster` (Autopilot, churn workloads) and `autoscaler-gke` (Standard, this project). They share project quotas — but at solo-portfolio scale, project quotas are not the binding constraint; *billing-account GPU eligibility* is. Splitting projects would not have helped.

### GCP infrastructure

| Resource | Details |
|----------|---------|
| GKE Standard cluster | `autoscaler-gke`, `asia-south1`, regional control plane |
| Default node pool | `n2-standard-2` × 2 (KEDA, Prometheus, SigNoz, system) |
| GPU node pool | `g2-standard-8` × (0–3), 1× L4 each, **Spot** enabled, taint `nvidia.com/gpu=present:NoSchedule` |
| VPC | `autoscaler-network` with `autoscaler-subnet`, secondary IP ranges for pods/services |
| Service account | `gke-nodes` with default OAuth scopes |
| Workload Identity | Enabled (pod-level GCP auth without keys) |

### Local vind cluster (for non-GPU dev)

vind is for *non-GPU* development only — vLLM with `facebook/opt-125m` runs on CPU (slow but correct). Use it to:
- Test Helm chart rendering
- Iterate on KEDA ScaledObject queries
- Verify Prometheus + ServiceMonitor wiring without burning GPU credit

```bash
vcluster create autoscaler-dev --values vind/vcluster.yaml
```

### vLLM serving

- Helm chart at `helm/vllm-server/`
- Default values (`values.yaml`): GPU production — L4, Qwen3-8B-Instruct AWQ-INT4, GPU tolerations + nodeSelector
- Override `values-cpu-dev.yaml` for vind: switches to opt-125m, disables GPU, lifts memory limits
- ServiceMonitor labeled `release: prometheus` so kube-prometheus-stack picks it up
- Readiness probe: `initialDelaySeconds: 30, periodSeconds: 10, failureThreshold: 6` (model load takes 25-40s on L4)
- vLLM args: `--max-model-len 2048 --quantization awq --disable-log-requests`

### KEDA ScaledObject

- Helm chart at `helm/keda-scaler/`
- Two Prometheus triggers (KEDA evaluates each independently and takes the max desired replica count):
  - `vllm:num_requests_waiting > 5` (queue is building → lagging signal)
  - `vllm:gpu_cache_usage_perc > 0.85` (KV cache pressure → leading signal)
- `pollingInterval: 15s`
- `cooldownPeriod: 300s` (avoid thrashing under spot preemption)
- `minReplicaCount: 0` (scale to zero when idle, releases the GPU node)
- `maxReplicaCount: 3` (capped by L4 quota)

### Load testing

- Locust scripts at `load-test/`
- Three scenarios:
  - `steady.py` — 5 RPS for 5 min, baseline TTFT
  - `burst.py` — 5 RPS → 50 RPS spike, the autoscaling demo
  - `soak.py` — 30 min sustained 20 RPS, find the steady-state replica count
- Prompt corpus: realistic Indian-language prompts (Hindi, English, Hinglish) of variable length 50-1500 tokens, sampled from open datasets

## File layout

```
autoscaler/
├── README.md                  # Recruiter-facing
├── CLAUDE.md                  # This file (dev context)
├── EXPLANATION.md             # Deep technical walkthrough (TBD)
├── Makefile                   # All dev commands
├── pyproject.toml             # uv deps for load-test + scripts
│
├── gcp/                       # Terraform IaC
│   ├── main.tf                # GKE cluster + VPC
│   ├── gpu-pool.tf            # L4 spot node pool (separate file for clean diffs)
│   ├── variables.tf
│   ├── providers.tf
│   ├── terraform.tfvars       # gitignored
│   └── README.md
│
├── helm/
│   ├── vllm-server/           # vLLM Deployment + Service + ServiceMonitor
│   │   ├── values.yaml          # Default: GPU prod
│   │   ├── values-cpu-dev.yaml  # vind override: opt-125m on CPU
│   │   └── templates/
│   └── keda-scaler/           # ScaledObject + (optional) TriggerAuthentication
│
├── monitoring/
│   ├── prometheus/            # kube-prometheus-stack values + recording rules
│   └── signoz/                # SigNoz values + dashboards JSON
│
├── load-test/                 # Locust
│   ├── locustfile.py
│   ├── prompts.py
│   └── scenarios/
│
├── vind/                      # Local vcluster config
│
└── scripts/                   # One-off helpers (bootstrap, verify, port-forward)
```

## What's done vs TODO

### Done
- [x] Repo scaffold
- [x] Helm chart skeleton for vLLM (Deployment, Service, ServiceMonitor — CPU-default)
- [x] Terraform IaC for GKE Standard cluster (CPU-only base pool)
- [x] kube-prometheus-stack values
- [x] SigNoz values
- [x] vind local config

### TODO (Phase 0)
- [ ] Set up Cloud-Function billing kill-switch on existing project (budget ₹6,500/mo, Pub/Sub → Cloud Function disables billing — budgets alone don't cap spend)
- [ ] Verify billing account (one-time fraud check — does NOT unlock GPU quota by itself, but is a prerequisite for Sales review)
- [ ] Build CPU usage history — keep customer_churn's Autopilot cluster running for 5-7 days to satisfy the "established billing account" eligibility heuristic
- [ ] Try Cloud Run L4 backdoor in `us-central1` (Google auto-grants 3 L4 quota on first successful deploy; this flips the eligibility flag)
- [ ] File the GKE L4 quota request via Sales contact form (NOT the quota form — auto-denies). Justify with: vLLM + KEDA portfolio project, $50-100/mo commit, paid+IDV+CPU-history account state. Expected reply: 2-3 business days.
- [ ] Request L4 + Preemptible-L4 GPU quota in `asia-south1` (4 GPUs)
- [ ] Add L4 spot node pool to `gcp/gpu-pool.tf` with autoscale 0→3
- [ ] Update vLLM Helm chart for GPU production: tolerations, nodeSelector, AWQ model, GPU resource request
- [ ] Build KEDA ScaledObject Helm chart with both triggers
- [ ] Locust load-test scripts (steady / burst / soak)
- [ ] Prometheus recording rules (derived TTFT, throughput rates)
- [ ] SigNoz dashboards (TTFT distribution, KV cache, replica count, autoscaler events)
- [ ] End-to-end smoke test → record demo

### Phase 1+ (planned)
- [ ] Multi-LoRA serving (1 base + 10 adapters, header-routed, per-tenant rate limit)
- [ ] Quantization comparison harness (FP16 vs FP8 vs AWQ-INT4 on 7B)
- [ ] EAGLE-3 speculative decoding integration
- [ ] PD-disaggregated autoscaler with llm-d

### Explicitly out of scope
- Training or fine-tuning models — that's customer_churn's job
- AKS/EKS deployment (mentioned as theoretical portability, not actually built)
- Multi-region HA
- Production-grade SigNoz (single replica, demo-grade retention)

## Key decisions and context

- **GKE Standard, not Autopilot.** Autopilot is great for stateless apps but doesn't give per-pool control of GPU node configuration (taints, instance type, spot, preemption tolerance). For a project whose whole point is GPU node-pool tuning, Standard is the right call. customer_churn uses Autopilot for the opposite reason — no GPUs, simpler ops.
- **L4 over T4 / A100.** T4 (16GB) can't host a 7B-class model with credible KV cache pressure. A100 (40GB) burns trial credit fast (~$3.4/hr spot all-in). L4 (24GB) is the sweet spot — fits Mistral-7B AWQ + meaningful KV cache, ~$0.30/hr on spot.
- **Qwen3-8B-Instruct AWQ-INT4 as default.** Popular 2026 open model from Alibaba; fits on L4 (~5GB weights + KV cache headroom). Picked over Mistral-7B for popularity (Qwen3 is what people are deploying right now). Picked over Kimi-K because Moonshot's Kimi-K2 is a 1T-param MoE that needs 128 H200s — there's no L4-friendly Kimi variant as of early 2026. Picked over Sarvam-M because Sarvam-M is gated on HF and larger than L4 can credibly host.
- **Spot over on-demand.** ~70% cost savings. L4 spot reclamation happens roughly daily, completes in ~30s; KEDA's 300s cooldown absorbs this. For *recorded demos*, switch the node pool to on-demand briefly to avoid mid-recording preemption.
- **KEDA standalone, no separate HPA.** KEDA *is* an HPA under the hood — it generates one with custom-metric triggers. No need to layer an HPA on top.
- **Helm over raw YAML.** customer_churn deliberately uses raw YAML because it has 4 manifests and one environment. autoscaler has 3 deployment shapes (vind dev / GKE GPU prod / future llm-d) and 3 charts. Helm pays for itself.
- **SigNoz over Grafana.** customer_churn doesn't run Grafana either. SigNoz's OTel-native model + single platform for traces+metrics+logs is a better fit for inference observability than Grafana + Tempo + Loki separately.
- **Same GCP project as customer_churn (reversed earlier plan).** Initial plan was to split projects for IAM/blast-radius reasons. Research showed quota and credits are billing-account-scoped, not project-scoped — splitting projects would not have given us more GPU quota and only added gcloud-context overhead. At solo-portfolio scale, one project + namespace separation is the right call. Cited: [Google's allocation-quotas doc](https://docs.cloud.google.com/compute/resource-usage), [OneUptime quota guide Feb 2026](https://oneuptime.com/blog/post/2026-02-17-how-to-resolve-quota-exceeded-errors-for-compute-engine-cpu-and-gpu-resources/view).
- **GPU quota unlock playbook (verified May 2026).** "Paid account" status alone does NOT unlock GPU quota — eligibility gates on billing-cycle history + non-GPU usage history + Sales contact form. ID verification is fraud-check only, not GPU-eligibility. Cloud Run L4 in any region auto-grants 3 quota on first deploy and flips the billing-account eligibility flag — useful as a backdoor before requesting GKE L4 quota. Cited: [Cloud Run GPU docs](https://docs.cloud.google.com/run/docs/configuring/services/gpu), [student journey Sept 2025](https://discuss.google.dev/t/a-students-detailed-2-day-journey-blocked-on-gpu-quota-despite-id-verification-case-on-request/263629).

## Git and tooling preferences

- **Never use pip** — always `uv add`, `uv run`, `uv sync`
- **Never use kind** — use vind (vcluster with Docker driver)
- **Never add co-authored-by lines** to commits
- **SSH remote**: `git@github-personal:my-neme-eh-jeff/<repo>.git` (custom SSH alias for the personal GitHub account)
- **Use real datasets / models** from HuggingFace / open sources, not synthetic stubs
- **GCS for storage** — `gcloud` CLI logged in with `aman2003raj0@gmail.com` (personal) and `aman.nambisan@atlan.com` (work, used by ADC). Atlan account has `storage.objectAdmin` on GCS buckets used for sharing.
- **GitHub accounts**: `Aman-Nambisan` (personal, gh CLI) and `my-neme-eh-jeff` (portfolio account, used for this project). Container images, if any, go under `my-neme-eh-jeff` ghcr namespace.

## Known infra quirks

- **GCP free-trial credits + GPU.** GPUs are *blocked* during the trial-tier state, but unlock once the billing account is upgraded to "Paid account". Remaining trial credits then apply to GPU spend up to the credit's 90-day expiration. Verified via on-record Google Cloud Support replies in the [gce-discussion forum](https://groups.google.com/g/gce-discussion/c/JoOwDMtMgFk).
- **L4 GPU quota is project-scoped, not org-scoped.** The org-level quotas page shows "Unlimited (Projects limit enforced)". Request the actual quota inside the *specific* project context (`IAM & Admin → Quotas` with project picker set, not org). Initial L4 quota in `asia-south1` is often 0; auto-approval typically takes minutes for L4/T4.
- **Two GKE clusters under one billing account is fine.** Project quotas are per-project, not per-billing-account. Running customer_churn's Autopilot cluster + autoscaler's Standard cluster simultaneously triggers no cross-project quota; they share only the credit pool.
- **vLLM readiness probe must allow ≥30s cold start.** A 7B AWQ model loads in ~25-40s on L4. Default probes (10s initial + 1s period + 3 failures) will kill the pod before the model finishes loading.
- **L4 spot preemption.** Roughly once per 24h, ~30s drain notice. KEDA's `cooldownPeriod: 300s` absorbs this without thrash. For recorded demos, switch the node pool to on-demand briefly to avoid mid-demo preemption.
- **vLLM ServiceMonitor must be labeled `release: prometheus`.** kube-prometheus-stack's `serviceMonitorSelector` defaults to that label. Without it, Prometheus silently doesn't scrape — no error, just an empty target list.
- **AWQ models on vLLM need explicit `--quantization awq`.** vLLM doesn't auto-detect from the model card; pass it explicitly in `values.yaml`.
- **GKE Standard cluster fee.** $0.10/hr per cluster. One cluster is free per billing account per month; the second one (this project's) is billed. About $72/mo if running 24/7 — argument for `terraform destroy` between sessions.

## Next session goals

1. **Set up the billing kill-switch FIRST** — Cloud Function that disables billing at ₹6,500/mo threshold. Budgets alone don't cap spend.
2. Verify billing account (already submitted 2026-05-03) — fraud check, prerequisite for Sales review.
3. Keep customer_churn's Autopilot cluster running for 5-7 days to accrue "established billing account" usage history.
4. **Cloud Run L4 backdoor**: deploy a stub vLLM container to Cloud Run in `us-central1` with `nvidia-l4` enabled. First successful deploy auto-grants 3 L4 quota and flips the eligibility flag.
5. File GKE L4 quota request via **Sales contact form** (https://cloud.google.com/contact), NOT the in-console quota form (auto-denies). Justification template lives in this repo (TBD: add to `docs/QUOTA-REQUEST.md`).
6. (No new project — reuse `project-8018ed81-1dfe-470e-aad`, just add new namespaces and a separate GKE Standard cluster.)
6. Add L4 spot node pool to `gcp/gpu-pool.tf`
7. Update vLLM Helm chart for GPU production (tolerations, nodeSelector, Qwen3-8B AWQ model)
8. Build KEDA ScaledObject Helm chart
9. Write Locust load test scripts
10. End-to-end smoke test on GKE: deploy → scrape metrics → ramp Locust → watch KEDA scale
11. Build SigNoz dashboards
12. Record demo video
