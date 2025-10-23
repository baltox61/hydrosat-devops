resource "kubernetes_namespace" "data" {
  metadata {
    name = var.dagster_namespace
  }
}

resource "helm_release" "dagster" {
  name       = "dagster"
  repository = "https://dagster-io.github.io/helm"
  chart      = "dagster"
  # Keep the version aligned with your cluster/K8s
  version    = "1.11.13"
  namespace  = var.dagster_namespace
  wait       = true

  # If you create nodes elsewhere, keep this depends_on; otherwise remove it
  depends_on = [aws_eks_node_group.default]

  # Use yamlencode so array/map paths (like userDeployments.deployments[0].image.*) render correctly
  values = [
    yamlencode({
      global = {
        # Set the default image for all Dagster components including run launcher
        dagsterImage = {
          repository = var.dagster_image_repository
          tag        = var.dagster_image_tag
          pullPolicy = "Always"
        }
      }

      # Service account for Dagster with IRSA for S3 access
      serviceAccount = {
        create = true
        annotations = {
          "eks.amazonaws.com/role-arn" = module.iam_role_dagster.iam_role_arn
        }
      }

      # Enable the user deployments subchart and provide our custom image
      # Note: Must use "dagster-user-deployments" (with hyphens) not "userDeployments"
      "dagster-user-deployments" = {
        enabled = true

        # Service account for user deployments with IRSA for S3 access
        # This service account is used by both user deployment pods and job run pods
        serviceAccount = {
          create = true
          annotations = {
            "eks.amazonaws.com/role-arn" = module.iam_role_dagster.iam_role_arn
          }
        }

        deployments = [
          {
            name  = "weather"
            image = {
              repository = var.dagster_image_repository
              tag        = var.dagster_image_tag
              pullPolicy = "Always"
            }

            # Specify the correct module path for Dagster code location
            dagsterApiGrpcArgs = [
              "-m", "dagster_weather.weather_pipeline"
            ]

            port = 3030

            # Additional ports for the container
            ports = [
              {
                name          = "metrics"
                containerPort = 9090
                protocol      = "TCP"
              }
            ]

            env = [
              # Vault configuration will be loaded from /secrets/.env by the app
            ]

            # Vault Agent init container configuration
            includeConfigInLaunchedRuns = {
              enabled = true
            }

            # Prometheus annotations for metrics scraping
            annotations = {
              "prometheus.io/scrape" = "true"
              "prometheus.io/port"   = "9090"
              "prometheus.io/path"   = "/metrics"
            }

            volumes = [
              {
                name = "vault-config"
                configMap = {
                  name = "dagster-vault-config"
                }
              },
              {
                name      = "vault-token"
                emptyDir  = { medium = "Memory" }
              },
              {
                name      = "app-secrets"
                emptyDir  = { medium = "Memory" }
              }
            ]

            volumeMounts = [
              {
                name      = "vault-config"
                mountPath = "/vault/config"
              },
              {
                name      = "vault-token"
                mountPath = "/var/run/vault"
              },
              {
                name      = "app-secrets"
                mountPath = "/secrets"
              }
            ]

            # Vault Agent init container
            initContainers = [
              {
                name  = "vault-agent"
                image = "hashicorp/vault:1.15"
                args  = ["agent", "-config=/vault/config/vault-agent-config.hcl"]

                env = [
                  {
                    name = "VAULT_ADDR"
                    value = "http://vault.vault.svc.cluster.local:8200"
                  }
                ]

                volumeMounts = [
                  {
                    name      = "vault-config"
                    mountPath = "/vault/config"
                  },
                  {
                    name      = "vault-token"
                    mountPath = "/var/run/vault"
                  },
                  {
                    name      = "app-secrets"
                    mountPath = "/secrets"
                  }
                ]

                resources = {
                  requests = {
                    cpu    = "50m"
                    memory = "64Mi"
                  }
                  limits = {
                    cpu    = "100m"
                    memory = "128Mi"
                  }
                }
              }
            ]

            resources = {
              requests = {
                cpu    = "100m"
                memory = "256Mi"
              }
              limits = {
                cpu    = "500m"
                memory = "512Mi"
              }
            }
          }
        ]
      }

      # PostgreSQL configuration
      postgresql = {
        enabled = true
        persistence = {
          enabled      = true
          storageClass = "gp2"
          size         = "8Gi"
        }
      }

      # Run launcher configuration - tells Dagster to use custom image with IRSA
      # Job pods inherit the global dagsterImage configuration
      runLauncher = {
        type = "K8sRunLauncher"
        config = {
          k8sRunLauncher = {
            # Always pull latest image for job pods
            imagePullPolicy = "Always"
            # Use service account with IRSA for S3 access
            runK8sConfig = {
              podSpecConfig = {
                serviceAccountName = "dagster"
              }
              # Container configuration for job run pods
              containerConfig = {
                resources = {
                  requests = {
                    cpu    = "100m"
                    memory = "256Mi"
                  }
                  limits = {
                    cpu    = "1000m"
                    memory = "1Gi"
                  }
                }
              }
              #  Automatically clean up completed job pods after 1 hour (3600 seconds)
              jobSpecConfig = {
                ttlSecondsAfterFinished = 3600
              }
            }
          }
        }
      }

      # Optional: enable the webserver / dagit and daemon if not already
      dagit = {
        enabled = true
      }

      dagsterDaemon = {
        enabled = true
      }
    })
  ]
}

