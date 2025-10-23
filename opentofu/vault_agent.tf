# Vault Agent ConfigMaps for secret templating
# This replaces the init container approach with vault-agent templating

locals {
  vault_addr = "http://vault.vault.svc.cluster.local:8200"
  app_path   = "/secrets"
}

# Dagster Vault Agent ConfigMap
resource "kubernetes_config_map" "vault_dagster" {
  metadata {
    name      = "dagster-vault-config"
    namespace = var.dagster_namespace
    labels = {
      app = "dagster"
    }
  }

  data = {
    "vault-agent-config.hcl" = <<-EOF
      exit_after_auth = true
      pid_file = "/home/vault/pidfile"

      vault {
        address = "${local.vault_addr}"
        retry {
          enabled  = true
          attempts = 6
          backoff  = "500ms"
        }
      }

      auto_auth {
        method "kubernetes" {
          mount_path = "auth/kubernetes"
          config = {
            role = "dagster-role"
          }
        }

        sink "file" {
          config = {
            path = "/var/run/vault/.vault-token"
          }
        }
      }

      template {
        destination = "${local.app_path}/.env"
        contents = <<EOT
{{ with secret "secret/data/${var.cluster_name}/openweather-api-key" }}OPENWEATHER_API_KEY={{ .Data.data.key }}
{{ end -}}
{{ with secret "secret/data/${var.cluster_name}/postgres/dagster-db-password" }}DAGSTER_DB_PASSWORD={{ .Data.data.password }}
{{ end -}}
{{ with secret "secret/data/${var.cluster_name}/aws/s3-bucket-name" }}WEATHER_RESULTS_BUCKET={{ .Data.data.bucket }}
{{ end -}}
{{ with secret "secret/data/dagster/pipeline-config" }}FETCH_INTERVAL={{ .Data.data.fetch_interval }}
{{ end -}}
{{ with secret "secret/data/dagster/coordinates" }}LAT={{ .Data.data.lat }}
LON={{ .Data.data.lon }}
{{ end -}}
EOT
      }
    EOF
  }

  depends_on = [kubernetes_namespace.data]
}

# API Vault Agent ConfigMap
resource "kubernetes_config_map" "vault_api" {
  metadata {
    name      = "api-vault-config"
    namespace = var.dagster_namespace
    labels = {
      app = "products-api"
    }
  }

  data = {
    "vault-agent-config.hcl" = <<-EOF
      exit_after_auth = true
      pid_file = "/home/vault/pidfile"

      vault {
        address = "${local.vault_addr}"
        retry {
          enabled  = true
          attempts = 6
          backoff  = "500ms"
        }
      }

      auto_auth {
        method "kubernetes" {
          mount_path = "auth/kubernetes"
          config = {
            role = "api-role"
          }
        }

        sink "file" {
          config = {
            path = "/var/run/vault/.vault-token"
          }
        }
      }

      template {
        destination = "${local.app_path}/.env"
        contents = <<EOT
{{ with secret "secret/data/${var.cluster_name}/aws/s3-bucket-name" }}WEATHER_RESULTS_BUCKET={{ .Data.data.bucket }}
{{ end -}}
{{ with secret "secret/data/api/rate-limits" }}MAX_REQUESTS={{ .Data.data.max_requests }}
{{ end -}}
EOT
      }
    EOF
  }

  depends_on = [kubernetes_namespace.data]
}
