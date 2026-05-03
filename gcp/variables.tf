variable "gcp_project_id" {
  description = "GCP project ID"
  type        = string
}

variable "gcp_region" {
  description = "GCP region for resources"
  type        = string
  default     = "us-central1"
}

variable "cluster_name" {
  description = "GKE cluster name"
  type        = string
  default     = "autoscaler-gke"
}

variable "cluster_zone" {
  description = "GKE cluster zone"
  type        = string
  default     = "us-central1-a"
}

variable "node_count" {
  description = "Initial number of nodes in the cluster"
  type        = number
  default     = 2
}

variable "min_node_count" {
  description = "Minimum number of nodes (autoscaling)"
  type        = number
  default     = 2
}

variable "max_node_count" {
  description = "Maximum number of nodes (autoscaling)"
  type        = number
  default     = 10
}

variable "machine_type" {
  description = "GCE machine type for nodes"
  type        = string
  default     = "n1-standard-2"  # 2 vCPU, 7.5 GB RAM — good for light inference + observability
}

variable "disk_size_gb" {
  description = "Boot disk size in GB for nodes"
  type        = number
  default     = 100
}

variable "enable_workload_identity" {
  description = "Enable Workload Identity for pod-to-GCP auth"
  type        = bool
  default     = true
}

variable "network_name" {
  description = "VPC network name"
  type        = string
  default     = "autoscaler-network"
}

variable "subnetwork_name" {
  description = "VPC subnetwork name"
  type        = string
  default     = "autoscaler-subnet"
}

variable "ip_range_pods" {
  description = "IP range for pods (secondary CIDR)"
  type        = string
  default     = "10.1.0.0/16"
}

variable "ip_range_services" {
  description = "IP range for services (secondary CIDR)"
  type        = string
  default     = "10.2.0.0/16"
}

# ─── GPU node pool (used by gpu-pool.tf) ──────────────────────────────────────

variable "gpu_machine_type" {
  description = "Machine family for the GPU pool. g2-standard-8 = 8 vCPU + 1× L4 (24GB VRAM)."
  type        = string
  default     = "g2-standard-8"
}

variable "gpu_accelerator_type" {
  description = "GPU accelerator SKU. nvidia-l4 is the L4-on-G2 pairing."
  type        = string
  default     = "nvidia-l4"
}

variable "gpu_max_nodes" {
  description = "Max nodes in the GPU pool. Capped by your granted L4 quota (start at 1, raise after Sales grants more)."
  type        = number
  default     = 3
}
