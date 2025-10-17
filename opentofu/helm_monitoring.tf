resource "kubernetes_namespace" "monitoring" {
  metadata { name = var.monitoring_namespace }
}

resource "helm_release" "kps" {
  name       = "kps"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  namespace  = var.monitoring_namespace
  version    = "65.1.0"
  wait       = true

  values = [yamlencode({
    grafana = {
      defaultDashboardsEnabled = true
      service = { type = "LoadBalancer" }
    }
    prometheus = { service = { type = "LoadBalancer" } }
  })]
}
