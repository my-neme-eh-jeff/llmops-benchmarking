# VPC Network for the cluster
resource "google_compute_network" "vpc" {
  name                    = var.network_name
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

# Subnetwork with secondary IP ranges for pods and services
resource "google_compute_subnetwork" "subnet" {
  name          = var.subnetwork_name
  ip_cidr_range = "10.0.0.0/20"
  region        = var.gcp_region
  network       = google_compute_network.vpc.id

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.ip_range_pods
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.ip_range_services
  }
}

# GKE Cluster
resource "google_container_cluster" "primary" {
  name     = var.cluster_name
  location = var.cluster_zone

  # Start with a single node pool that we'll configure
  initial_node_count       = var.node_count
  remove_default_node_pool = true

  # Network configuration
  network    = google_compute_network.vpc.name
  subnetwork = google_compute_subnetwork.subnet.name

  # IP allocation policy for secondary IP ranges (required for GKE)
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Cluster features
  logging_service    = "logging.googleapis.com/kubernetes"
  monitoring_service = "monitoring.googleapis.com/kubernetes"

  # Enable Workload Identity (pod-to-GCP service account binding)
  workload_identity_config {
    workload_pool = "${var.gcp_project_id}.svc.id.goog"
  }

  # Disable maintenance during load tests
  maintenance_policy {
    daily_maintenance_window {
      start_time = "03:00"  # UTC
    }
  }

  # Required for destroy
  deletion_protection = false
}

# Node pool with autoscaling
# This replaces the initial node pool that GKE creates by default.
# We parameterize min/max for easy tuning based on load test results.
resource "google_container_node_pool" "primary_nodes" {
  name       = "${var.cluster_name}-node-pool"
  location   = var.cluster_zone
  cluster    = google_container_cluster.primary.name
  node_count = var.node_count

  autoscaling {
    min_node_count = var.min_node_count
    max_node_count = var.max_node_count
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    preemptible = false  # Use standard nodes for stability; can switch to preemptible to save 70% costs
    machine_type = var.machine_type
    disk_size_gb = var.disk_size_gb

    # Google-managed default OAuth scopes
    oauth_scopes = [
      "https://www.googleapis.com/auth/compute",
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/trace.append",
    ]

    # Metadata for Workload Identity
    metadata = {
      disable-legacy-endpoints = "true"
    }

    # Workload Identity node metadata
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    # Labels for pod node selection
    labels = {
      environment = "dev"
      project     = "autoscaler"
    }

    # Taints to force certain workloads onto specific nodes (optional)
    # Uncomment if you want to reserve nodes for GPU in Phase 2
    # taint {
    #   key    = "workload-type"
    #   value  = "inference"
    #   effect = "NO_SCHEDULE"
    # }
  }

  # Metadata server security
  service_account = google_service_account.gke_nodes.email
}

# Service account for GKE nodes
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE Node Service Account"
}

# Outputs for kubectl configuration
output "cluster_name" {
  value       = google_container_cluster.primary.name
  description = "GKE cluster name"
}

output "region" {
  value       = var.gcp_region
  description = "GCP region"
}

output "zone" {
  value       = var.cluster_zone
  description = "GCP zone"
}

output "kubernetes_cluster_host" {
  value       = "https://${google_container_cluster.primary.endpoint}"
  description = "Kubernetes API server endpoint"
  sensitive   = true
}

output "project_id" {
  value       = var.gcp_project_id
  description = "GCP project ID"
}

output "connect_command" {
  value       = "gcloud container clusters get-credentials ${google_container_cluster.primary.name} --zone ${var.cluster_zone} --project ${var.gcp_project_id}"
  description = "Command to configure kubectl"
}
