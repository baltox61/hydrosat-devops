# Prometheus ServiceMonitors and PodMonitors for scraping application metrics
#
# These resources tell Prometheus (via the prometheus-operator) how to scrape
# custom application metrics from Dagster and the Products API.

# PodMonitor for Dagster user deployments
# Scrapes metrics directly from Dagster pods on port 9090
resource "kubectl_manifest" "dagster_podmonitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: PodMonitor
    metadata:
      name: dagster-metrics
      namespace: ${var.monitoring_namespace}
      labels:
        release: kps  # Required for Prometheus to discover this PodMonitor
    spec:
      namespaceSelector:
        matchNames:
          - ${var.dagster_namespace}
      selector:
        matchExpressions:
          - key: deployment
            operator: Exists
          - key: app.kubernetes.io/instance
            operator: In
            values: [dagster]
      podMetricsEndpoints:
        - port: metrics
          path: /metrics
          interval: 30s
          scrapeTimeout: 10s
          relabelings:
            - targetLabel: component
              replacement: user-deployments
  YAML

  depends_on = [
    helm_release.kps,
    helm_release.dagster
  ]
}

# ServiceMonitor for Products API
# Scrapes metrics from the Products API service on port 8080
resource "kubectl_manifest" "products_api_servicemonitor" {
  yaml_body = <<-YAML
    apiVersion: monitoring.coreos.com/v1
    kind: ServiceMonitor
    metadata:
      name: products-api
      namespace: ${var.monitoring_namespace}
      labels:
        release: kps  # Required for Prometheus to discover this ServiceMonitor
    spec:
      namespaceSelector:
        matchNames:
          - ${var.dagster_namespace}
      selector:
        matchLabels:
          app: products-api
      endpoints:
        - port: http
          path: /metrics
          interval: 30s
          scrapeTimeout: 10s
          relabelings:
            - targetLabel: service
              replacement: products-api
  YAML

  depends_on = [
    helm_release.kps,
    kubernetes_service.api
  ]
}
