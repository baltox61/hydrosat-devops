# Products API Kubernetes Deployment and Service
# IAM role for API is defined in iam.tf

# API Service Account with IRSA annotations
resource "kubernetes_service_account" "api" {
  metadata {
    name      = "products-api"
    namespace = var.dagster_namespace
    annotations = {
      "eks.amazonaws.com/role-arn" = module.iam_role_api.iam_role_arn
    }
  }
  depends_on = [kubernetes_namespace.data]
}

# API Deployment
resource "kubernetes_deployment" "api" {
  metadata {
    name      = "products-api"
    namespace = var.dagster_namespace
    labels = {
      app = "products-api"
    }
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "products-api"
      }
    }

    template {
      metadata {
        labels = {
          app = "products-api"
        }
        annotations = {
          "prometheus.io/scrape" = "true"
          "prometheus.io/port"   = "8000"
          "prometheus.io/path"   = "/metrics"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.api.metadata[0].name

        # Init container: Vault agent to fetch secrets
        init_container {
          name    = "vault-agent"
          image   = "hashicorp/vault:1.15"
          command = ["vault"]
          args    = ["agent", "-config=/vault/config/vault-agent-config.hcl"]

          env {
            name  = "VAULT_ADDR"
            value = "http://vault.vault.svc.cluster.local:8200"
          }

          env {
            name  = "VAULT_SKIP_VERIFY"
            value = "true"
          }

          volume_mount {
            name       = "vault-config"
            mount_path = "/vault/config"
          }

          volume_mount {
            name       = "app-secrets"
            mount_path = "/secrets"
          }

          volume_mount {
            name       = "vault-token"
            mount_path = "/var/run/vault"
          }
        }

        container {
          name  = "api"
          image = var.api_image

          env {
            name  = "ENV_FILE"
            value = "/secrets/.env"
          }

          env {
            name  = "WEATHER_RESULTS_PREFIX"
            value = "weather-products/"
          }

          port {
            container_port = 8000
            name           = "http"
          }

          # Mount vault-agent generated secrets
          volume_mount {
            name       = "app-secrets"
            mount_path = "/secrets"
            read_only  = true
          }

          # Resource limits
          resources {
            requests = {
              cpu    = "100m"
              memory = "128Mi"
            }
            limits = {
              cpu    = "500m"
              memory = "512Mi"
            }
          }

          # Liveness probe
          liveness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 10
            period_seconds        = 10
            timeout_seconds       = 5
            failure_threshold     = 3
          }

          # Readiness probe
          readiness_probe {
            http_get {
              path = "/health"
              port = 8000
            }
            initial_delay_seconds = 5
            period_seconds        = 5
            timeout_seconds       = 3
            failure_threshold     = 2
          }
        }

        volume {
          name = "app-secrets"
          empty_dir {
            medium = "Memory"
          }
        }

        volume {
          name = "vault-token"
          empty_dir {
            medium = "Memory"
          }
        }

        volume {
          name = "vault-config"
          config_map {
            name = "api-vault-config"
          }
        }
      }
    }
  }

  depends_on = [
    kubernetes_service_account.api,
    helm_release.vault
  ]
}

# API Service (ClusterIP for bastion-only access)
resource "kubernetes_service" "api" {
  metadata {
    name      = "products-api"
    namespace = var.dagster_namespace
    labels = {
      app = "products-api"
    }
  }

  spec {
    type = "ClusterIP"

    selector = {
      app = "products-api"
    }

    port {
      port        = 8080
      target_port = 8000
      protocol    = "TCP"
      name        = "http"
    }
  }

  depends_on = [kubernetes_deployment.api]
}
