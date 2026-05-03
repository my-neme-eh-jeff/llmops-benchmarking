# GCP Infrastructure as Code (Terraform)

Terraform configuration to provision a GKE cluster for the autoscaler project on Google Cloud Platform.

## Files

- **providers.tf** — Google provider configuration and Terraform version constraints
- **variables.tf** — Input variables (parameterized config)
- **terraform.tfvars** — Values for those variables (project-specific)
- **main.tf** — GKE cluster, node pool, network, and service account resources

## Prerequisites

```bash
# Install Terraform (or use `brew install terraform` on Mac)
terraform --version

# Authenticate with GCP
gcloud auth application-default login

# Ensure APIs are enabled (already done, but can verify)
gcloud services list --enabled --project=project-8018ed81-1dfe-470e-aad | grep container
```

## Usage

### 1. Plan the deployment (safe, shows what will be created)
```bash
cd gcp/
terraform init
terraform plan -out=tfplan
```

Review the plan output to ensure it matches expectations.

### 2. Apply the configuration (creates resources)
```bash
terraform apply tfplan
```

This will:
- Create a VPC network and subnetwork
- Provision a GKE cluster with 2 initial nodes
- Configure autoscaling (min 2, max 10 nodes)
- Set up Workload Identity for pod-to-GCP service account binding

**Expected time:** 5-10 minutes. Monitor progress in the GCP console:
https://console.cloud.google.com/kubernetes/clusters?project=project-8018ed81-1dfe-470e-aad

### 3. Configure kubectl after cluster is ready
```bash
gcloud container clusters get-credentials autoscaler-gke \
  --zone us-central1-a \
  --project project-8018ed81-1dfe-470e-aad
```

Or use the output from `terraform apply`:
```bash
terraform output -raw connect_command | bash
```

### 4. Verify the cluster
```bash
kubectl get nodes
kubectl get namespaces
```

### 5. Deploy the autoscaler stack (from parent directory)
```bash
cd ..
make install-keda
make install-prometheus
make install-signoz
make install-vllm
```

## Destroying the cluster

**WARNING:** This deletes all resources and data in the cluster.

```bash
terraform destroy
```

You'll be prompted to confirm. Type `yes` to proceed.

## Cost Optimization

- **Preemptible nodes:** Change `preemptible = false` to `true` in `main.tf` to save ~70% on compute costs (trade-off: nodes can be evicted with 30s notice)
- **Machine types:** Current config uses `n1-standard-2`. For larger models, upgrade to `n1-highmem-4` or `n1-highmem-8`
- **Free credits:** Monitor usage at https://console.cloud.google.com/billing/account

## Troubleshooting

### Terraform plan fails with "Kubernetes Engine API has not been used"
→ Ensure the API is enabled in GCP console (you already did this)

### Cluster creation hangs
→ Check GCP console for errors, or examine GKE logs:
```bash
gcloud container clusters describe autoscaler-gke \
  --zone us-central1-a \
  --project project-8018ed81-1dfe-470e-aad
```

### Can't connect to cluster with kubectl
→ Run the connect command again or re-authenticate with gcloud

## Next Steps

1. Deploy KEDA, Prometheus, SigNoz, and vLLM to this cluster
2. Configure GPU nodes for Phase 2 (swap machine types in terraform.tfvars)
3. Run Locust load tests and tune KEDA autoscaling thresholds
