# GPU-Aware LLM Autoscaler — Dev Commands
# vind docs: https://www.vcluster.com/blog/replacing-kind-with-vind-deep-dive

CLUSTER_NAME := autoscaler-dev

# ── Cluster lifecycle ─────────────────────────────────────────────────────────

.PHONY: cluster-up
cluster-up: ## Create the local vind cluster
	vcluster create $(CLUSTER_NAME) --values vind/vcluster.yaml

.PHONY: cluster-down
cluster-down: ## Delete the local vind cluster
	vcluster delete $(CLUSTER_NAME)

.PHONY: cluster-pause
cluster-pause: ## Suspend the cluster (frees resources without losing state)
	vcluster pause $(CLUSTER_NAME)

.PHONY: cluster-resume
cluster-resume: ## Wake the cluster back up
	vcluster resume $(CLUSTER_NAME)

.PHONY: cluster-connect
cluster-connect: ## Set kubeconfig context to the vind cluster
	vcluster connect $(CLUSTER_NAME)

# ── Installation ──────────────────────────────────────────────────────────────

.PHONY: install-keda
install-keda: ## Install KEDA into the cluster
	helm repo add kedacore https://kedacore.github.io/charts
	helm repo update
	helm install keda kedacore/keda --namespace keda --create-namespace

.PHONY: install-prometheus
install-prometheus: ## Install kube-prometheus-stack (Prometheus + Grafana)
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
	helm repo update
	helm install prometheus prometheus-community/kube-prometheus-stack \
		--namespace monitoring --create-namespace \
		--values monitoring/prometheus/values.yaml

.PHONY: install-signoz
install-signoz: ## Install SigNoz observability platform
	helm repo add signoz https://charts.signoz.io
	helm repo update
	helm install signoz signoz/signoz \
		--namespace platform --create-namespace \
		--values monitoring/signoz/values.yaml \
		--timeout 10m

.PHONY: signoz-ui
signoz-ui: ## Port-forward SigNoz UI to localhost:8080
	@POD=$$(kubectl get pods -n platform -l "app.kubernetes.io/name=signoz,app.kubernetes.io/component=signoz" -o jsonpath="{.items[0].metadata.name}") && \
	echo "SigNoz UI → http://localhost:8080" && \
	kubectl port-forward -n platform $$POD 8080:8080

.PHONY: install-vllm
install-vllm: ## Deploy vLLM server
	helm install vllm-server helm/vllm-server \
		--namespace vllm --create-namespace \
		--values helm/vllm-server/values.yaml

# ── Dev helpers ───────────────────────────────────────────────────────────────

.PHONY: metrics
metrics: ## Print raw vLLM Prometheus metrics
	kubectl port-forward -n vllm svc/vllm-server 8000:8000 &
	sleep 2
	curl -s http://localhost:8000/metrics | grep -E "vllm:|# HELP vllm"

.PHONY: load-test
load-test: ## Run Locust load test (requires vLLM to be running)
	cd load-test && pip install locust -q && locust --headless -u 20 -r 2 -t 60s

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'
