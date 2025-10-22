# ConfigMap containing custom Grafana dashboards
resource "kubernetes_config_map" "grafana_dashboards" {
  metadata {
    name      = "grafana-custom-dashboards"
    namespace = var.monitoring_namespace
    labels = {
      grafana_dashboard = "1"
    }
  }

  data = {
    "kubernetes-overview.json" = file("${path.module}/../monitoring/dashboards/kubernetes-overview.json")
    "product-api.json"         = file("${path.module}/../monitoring/dashboards/product-api.json")
    "dagster.json"             = file("${path.module}/../monitoring/dashboards/dagster.json")
  }

  depends_on = [
    kubernetes_namespace.monitoring,
    helm_release.kps
  ]
}
