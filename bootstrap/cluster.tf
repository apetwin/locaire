# ==========================================
# Construct KinD cluster
# ==========================================
resource "kind_cluster" "this" {
  name           = var.cluster_name
  wait_for_ready = true
  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"
    node {
      role  = "control-plane"
      image = "kindest/node:${var.kubernetes_version}"
    }
    node {
      role  = "worker"
      image = "kindest/node:${var.kubernetes_version}"
    }
    node {
      role  = "worker"
      image = "kindest/node:${var.kubernetes_version}"
    }
    networking {
      kube_proxy_mode = "ipvs"
    }
  }
}
