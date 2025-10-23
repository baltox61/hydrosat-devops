# Vault deployment for centralized secrets management
# Uses production-ready Raft storage with single replica for demo purposes
# Production would use 3-5 replicas with auto-unseal via AWS KMS

resource "kubernetes_namespace" "vault" {
  metadata {
    name = "vault"
  }

  depends_on = [aws_eks_cluster.this]
}

resource "kubernetes_service_account" "vault" {
  metadata {
    name      = "vault"
    namespace = kubernetes_namespace.vault.metadata[0].name
  }

  depends_on = [aws_eks_cluster.this]
}

resource "kubernetes_cluster_role_binding" "vault_auth_delegator" {
  metadata {
    name = "vault-auth-delegator"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "system:auth-delegator"
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.vault.metadata[0].name
    namespace = kubernetes_namespace.vault.metadata[0].name
  }
}

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.28.0"
  namespace  = kubernetes_namespace.vault.metadata[0].name

  values = [
    yamlencode({
      server = {
        serviceAccount = {
          create = false
          name   = kubernetes_service_account.vault.metadata[0].name
        }

        dataStorage = {
          enabled      = true
          size         = "10Gi"
          storageClass = "gp2"
        }

        # Single replica with Raft storage for demo
        # Production: ha.enabled = true, ha.replicas = 3-5
        ha = {
          enabled  = false
          replicas = 1
        }

        standalone = {
          enabled = true
          config  = <<-EOT
            ui = true

            listener "tcp" {
              tls_disable = 1
              address     = "[::]:8200"
              cluster_address = "[::]:8201"
            }

            storage "raft" {
              path = "/vault/data"
            }

            service_registration "kubernetes" {}

            # Seal configuration
            # Production: use auto-unseal with AWS KMS
            # seal "awskms" {
            #   region     = "${var.region}"
            #   kms_key_id = "alias/vault-unseal"
            # }
          EOT
        }

        service = {
          enabled = true
          type    = "ClusterIP"
        }

        # UI service for demo access
        ui = {
          enabled         = true
          serviceType     = "LoadBalancer"
          serviceNodePort = null
          externalPort    = 8200
        }

        # Resource requests for cost optimization
        resources = {
          requests = {
            memory = "256Mi"
            cpu    = "250m"
          }
          limits = {
            memory = "512Mi"
            cpu    = "500m"
          }
        }

        # Readiness/liveness probes
        readinessProbe = {
          enabled = true
          path    = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
        }

        livenessProbe = {
          enabled             = true
          path                = "/v1/sys/health?standbyok=true&sealedcode=204&uninitcode=204"
          initialDelaySeconds = 60
        }
      }

      injector = {
        enabled = false # We're using init containers, not the injector pattern
      }
    })
  ]

  depends_on = [
    aws_eks_node_group.default,
    kubernetes_namespace.vault,
    kubernetes_service_account.vault,
    kubernetes_cluster_role_binding.vault_auth_delegator
  ]
}

#############################################
# Outputs

# All outputs consolidated in outputs.tf
