#############################################
# Vault Configuration Outputs
#############################################

output "vault_policies" {
  description = "Created Vault policies"
  sensitive   = true
  value = {
    dagster_app = vault_policy.dagster_app.name
    api_app     = vault_policy.api_app.name
  }
}

output "vault_roles" {
  description = "Created Vault Kubernetes auth roles"
  sensitive   = true
  value = {
    dagster = vault_kubernetes_auth_backend_role.dagster.role_name
    api     = vault_kubernetes_auth_backend_role.api.role_name
  }
}

output "vault_auth_backend" {
  description = "Vault Kubernetes auth backend path"
  value       = vault_auth_backend.kubernetes.path
}
