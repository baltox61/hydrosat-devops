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

  depends_on = [aws_eks_node_group.default]

  values = [yamlencode({
    grafana = {
      defaultDashboardsEnabled = true
      service                  = { type = "LoadBalancer" }
    }
    prometheus = {
      service = { type = "LoadBalancer" }
      prometheusSpec = {
        # Enable Dagster metrics scraping
        additionalScrapeConfigs = [
          {
            job_name = "dagster"
            kubernetes_sd_configs = [
              {
                role = "pod"
                namespaces = {
                  names = [var.dagster_namespace]
                }
              }
            ]
            relabel_configs = [
              {
                source_labels = ["__meta_kubernetes_pod_label_component"]
                action        = "keep"
                regex         = "dagster-daemon|dagster-webserver|dagster-user-deployments"
              },
              {
                source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"]
                action        = "keep"
                regex         = "true"
              },
              {
                source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"]
                action        = "replace"
                target_label  = "__metrics_path__"
                regex         = "(.+)"
              }
            ]
          }
        ]
      }
    }

    # AlertManager configuration
    alertmanager = {
      enabled = true
      config = {
        route = {
          group_by        = ["alertname", "cluster", "service"]
          group_wait      = "10s"
          group_interval  = "10s"
          repeat_interval = "12h"
          receiver        = var.slack_webhook_url != "" ? "slack-notifications" : "null"
        }
        receivers = concat(
          [{
            name = "null"
          }],
          var.slack_webhook_url != "" ? [{
            name = "slack-notifications"
            slack_configs = [{
              api_url       = var.slack_webhook_url
              channel       = "#dagster-alerts"
              title         = "{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}"
              text          = "{{ range .Alerts }}*Alert:* {{ .Labels.alertname }}\n*Severity:* {{ .Labels.severity }}\n*Description:* {{ .Annotations.description }}\n{{ end }}"
              send_resolved = true
            }]
          }] : []
        )
      }
    }

    # Custom Prometheus Rules for Dagster
    additionalPrometheusRulesMap = {
      dagster-alerts = {
        groups = [
          {
            name     = "dagster"
            interval = "30s"
            rules = [
              {
                alert = "DagsterJobFailed"
                expr  = "increase(dagster_job_failure_total[5m]) > 0"
                for   = "1m"
                labels = {
                  severity = "critical"
                }
                annotations = {
                  summary     = "Dagster job has failed"
                  description = "A Dagster job has failed in the last 5 minutes. Check Dagit UI for details."
                }
              },
              {
                alert = "DagsterDaemonDown"
                expr  = "up{job=\"dagster\",component=\"dagster-daemon\"} == 0"
                for   = "5m"
                labels = {
                  severity = "warning"
                }
                annotations = {
                  summary     = "Dagster daemon is down"
                  description = "The Dagster daemon has been down for more than 5 minutes."
                }
              }
            ]
          }
        ]
      }
    }
  })]
}
