# Vault configuration: policies, Kubernetes auth, and role bindings
# This configures Vault after it has been initialized and unsealed

# Note: This configuration requires Vault to be initialized first
# Run: ./scripts/vault_init.sh before applying this configuration

# Get EKS cluster information from AWS
data "aws_eks_cluster" "this" {
  name = var.cluster_name
}

# Enable Kubernetes authentication backend
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
  path = "kubernetes"
}

# Configure Kubernetes auth to use the cluster's token reviewer
resource "vault_kubernetes_auth_backend_config" "kubernetes" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = data.aws_eks_cluster.this.endpoint

  # Use the cluster's CA certificate
  # Note: In practice, this should be retrieved from the cluster
  # For now, we rely on Vault's service account mounting the CA
  disable_local_ca_jwt = false
}

# Note: KV v2 secrets engine is enabled by vault_init.sh script
# This ensures secrets can be populated before Terraform runs
# If you need to manage it with Terraform, import it:
#   tofu import vault_mount.secret secret

#############################################
# Policies
#############################################

# Dagster app policy - read access to Dagster and cluster secrets
resource "vault_policy" "dagster_app" {
  name = "dagster-app"

  policy = <<-EOT
    # Read Dagster-specific secrets
    path "secret/data/dagster/*" {
      capabilities = ["read", "list"]
    }

    # Read cluster-wide secrets that Dagster needs
    path "secret/data/${var.cluster_name}/openweather-api-key" {
      capabilities = ["read"]
    }

    path "secret/data/${var.cluster_name}/postgres/*" {
      capabilities = ["read"]
    }

    path "secret/data/${var.cluster_name}/aws/*" {
      capabilities = ["read"]
    }
  EOT
}

# API app policy - read access to API and cluster secrets
resource "vault_policy" "api_app" {
  name = "api-app"

  policy = <<-EOT
    # Read API-specific secrets
    path "secret/data/api/*" {
      capabilities = ["read", "list"]
    }

    # Read cluster-wide secrets that API needs
    path "secret/data/${var.cluster_name}/postgres/*" {
      capabilities = ["read"]
    }

    path "secret/data/${var.cluster_name}/aws/*" {
      capabilities = ["read"]
    }
  EOT
}

#############################################
# Kubernetes Auth Roles
#############################################

# Dagster role - bound to dagster-user-deployments service account created by Helm chart
resource "vault_kubernetes_auth_backend_role" "dagster" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "dagster-role"
  bound_service_account_names      = ["dagster-dagster-user-deployments-user-deployments"]
  bound_service_account_namespaces = ["data"]
  token_ttl                        = 3600 # 1 hour
  token_policies                   = [vault_policy.dagster_app.name]
}

# API role - bound to products-api service account
resource "vault_kubernetes_auth_backend_role" "api" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "api-role"
  bound_service_account_names      = ["products-api"]
  bound_service_account_namespaces = ["data"]
  token_ttl                        = 3600 # 1 hour
  token_policies                   = [vault_policy.api_app.name]
}

#############################################
# Service Accounts
#############################################

# Note: products-api service account is defined in k8s_api.tf with IRSA annotations
# Note: dagster-user-code service account is created by the Dagster Helm chart

#############################################

# All outputs consolidated in outputs.tf
