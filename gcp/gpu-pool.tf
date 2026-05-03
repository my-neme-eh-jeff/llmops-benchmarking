# L4 spot GPU node pool for vLLM inference workloads.
# Pods scheduled here are tainted-only (KEDA-managed vLLM) — system pods
# stay on the default n1-standard-2 pool created in main.tf.
#
# Scaling shape: cluster-autoscaler manages 0-3 nodes here, KEDA manages
# 0-3 vLLM pods on top. When the last vLLM pod scales to zero, the L4
# node drains and is reclaimed → hourly cost drops to ~$0.10 (control
# plane only).
#
# PREREQUISITE: NVIDIA L4 GPU quota must be granted in the target region.
# `terraform apply` will fail with "Quota 'NVIDIA_L4_GPUS' exceeded" if
# quota is not yet granted. See CLAUDE.md > "Next session goals" for the
# Cloud Sales contact form unlock path.

resource "google_container_node_pool" "gpu_pool" {
  name     = "${var.cluster_name}-gpu-pool"
  location = var.cluster_zone
  cluster  = google_container_cluster.primary.name

  # Start at 0 — cluster-autoscaler provisions a node when KEDA scales
  # the first vLLM pod up.
  initial_node_count = 0

  autoscaling {
    min_node_count = 0
    max_node_count = var.gpu_max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    # g2-standard-8: 8 vCPU, 32GB RAM, 1× L4 (24GB VRAM).
    # Sweet spot for a 7-8B AWQ-INT4 model + meaningful KV cache headroom.
    # Larger machine types attach more L4s — overkill for single-pod-per-node.
    machine_type = var.gpu_machine_type
    disk_size_gb = 100
    disk_type    = "pd-balanced"

    # Spot VMs: ~50-70% cheaper than on-demand. L4 spot reclamation
    # happens roughly daily with ~30s drain notice. KEDA's 300s cooldown
    # absorbs single-node preemption without pod-level thrashing.
    # For RECORDED demos, set spot=false briefly to avoid mid-recording preemption.
    spot = true

    # GPU attachment
    guest_accelerator {
      type  = var.gpu_accelerator_type
      count = 1

      # GKE auto-installs the NVIDIA driver via DaemonSet on first GPU node
      # in the cluster. "DEFAULT" pins to the GKE-recommended driver version
      # for the node's Kubernetes version.
      gpu_driver_installation_config {
        gpu_driver_version = "DEFAULT"
      }
    }

    # nodeSelector targets from the vLLM Deployment ride on this label.
    labels = {
      environment = "dev"
      project     = "autoscaler"
      accelerator = var.gpu_accelerator_type
      pool        = "gpu"
    }

    # Taint so only pods that explicitly tolerate `nvidia.com/gpu=present:NoSchedule`
    # land on this expensive pool. vLLM Deployment tolerates it; everything
    # else (KEDA operator, Prometheus, SigNoz) stays on the default CPU pool.
    taint {
      key    = "nvidia.com/gpu"
      value  = "present"
      effect = "NO_SCHEDULE"
    }

    # Full cloud-platform scope so future workloads can hit GCS / Secret Manager
    # without per-API scope edits. Tighten if/when concrete needs are known.
    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
    ]

    # Workload Identity — pod-level GCP auth without service account keys.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    metadata = {
      disable-legacy-endpoints = "true"
    }
  }

  # Reuse the node service account from main.tf
  service_account = google_service_account.gke_nodes.email

  lifecycle {
    ignore_changes = [
      # GKE rotates node metadata on auto-upgrade; ignore to prevent churn.
      node_config[0].metadata,
    ]
  }

  depends_on = [google_container_cluster.primary]
}

# Convenience output — verify L4 nodes register after the pool comes up.
output "gpu_pool_verify_command" {
  value       = "kubectl get nodes -l accelerator=${var.gpu_accelerator_type} -o wide"
  description = "Run after `terraform apply` succeeds to confirm the L4 node pool is registered with the cluster"
}

output "gpu_pool_taint_info" {
  value       = "Pods need: tolerations[{key: nvidia.com/gpu, operator: Equal, value: present, effect: NoSchedule}] AND nodeSelector: { accelerator: ${var.gpu_accelerator_type} }"
  description = "How vLLM pods get scheduled onto this pool"
}
