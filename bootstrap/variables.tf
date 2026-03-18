variable "cluster_name" {
  description = "Cluster Name"
  type        = string
  default     = "aibox"
}

variable "kubernetes_version" {
  description = "Kubernetes version for KinD node image"
  type        = string
  default     = "v1.35.0"
  # Verify the exact patch tag at https://github.com/kubernetes-sigs/kind/releases
}

variable "oci_registry" {
  description = "OCI registry base URL"
  type        = string
  default     = "oci://ghcr.io/apetwin/aibox"
  # Replace YOUR_GITHUB_USERNAME with your actual GitHub username before running
}

variable "releases_version" {
  description = "Default tag for releases OCI artifact bootstrap"
  type        = string
  default     = "0.1.0"
}
