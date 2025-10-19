#############################################
# EKS Cluster Outputs
#############################################

output "cluster_id" {
  description = "EKS cluster ID"
  value       = aws_eks_cluster.this.id
}

output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.this.name
}

output "cluster_addons" {
  description = "EKS cluster addons installed"
  value = {
    kube_proxy      = aws_eks_addon.kube_proxy.addon_version
    coredns         = aws_eks_addon.coredns.addon_version
    vpc_cni         = aws_eks_addon.vpc_cni.addon_version
    ebs_csi_driver  = aws_eks_addon.ebs_csi_driver.addon_version
  }
}

output "cluster_endpoint" {
  description = "EKS cluster endpoint"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = aws_eks_cluster.this.certificate_authority[0].data
  sensitive   = true
}

output "cluster_oidc_issuer_url" {
  description = "The URL on the EKS cluster OIDC Issuer"
  value       = try(aws_eks_cluster.this.identity[0].oidc[0].issuer, null)
}

#############################################
# IAM Outputs
#############################################

output "cluster_iam_role_arn" {
  description = "IAM role ARN for EKS cluster"
  value       = aws_iam_role.cluster.arn
}

output "node_iam_role_arn" {
  description = "IAM role ARN for EKS nodes"
  value       = aws_iam_role.node.arn
}

output "node_iam_role_name" {
  description = "IAM role name for EKS nodes"
  value       = aws_iam_role.node.name
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC Provider for EKS"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "oidc_provider_url" {
  description = "URL of the OIDC Provider for EKS"
  value       = aws_iam_openid_connect_provider.cluster.url
}

output "dagster_iam_role_arn" {
  description = "IAM role ARN for Dagster service account (IRSA)"
  value       = module.iam_role_dagster.iam_role_arn
}

output "api_iam_role_arn" {
  description = "IAM role ARN for API service account (IRSA)"
  value       = module.iam_role_api.iam_role_arn
}

#############################################
# Security Group Outputs
#############################################

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_security_group.cluster.id
}

output "node_security_group_id" {
  description = "Security group ID attached to the EKS nodes"
  value       = aws_security_group.node.id
}

#############################################
# S3 Outputs
#############################################

output "products_bucket" {
  description = "S3 bucket name for weather products"
  value       = aws_s3_bucket.products.bucket
}

#############################################
# Vault Outputs
#############################################

output "vault_addr" {
  description = "Vault internal cluster address"
  value       = "http://vault.vault.svc.cluster.local:8200"
}

# Note: Vault policies and roles are configured in the vault-config/ directory
# To see Vault-related outputs: cd opentofu/vault-config && tofu output

#############################################
# Application Outputs & Instructions
#############################################

output "dagster_web_url_hint" {
  description = "Instructions to access Dagster UI"
  value       = "After LB is ready, open Dagit at http(s)://<dagster-webserver-EXTERNAL-IP>/"
}

output "vault_ui_instructions" {
  description = "Instructions to access Vault UI"
  value       = "kubectl -n vault port-forward svc/vault-ui 8200:8200 then open http://localhost:8200"
}

output "vault_init_instructions" {
  description = "Instructions to initialize and unseal Vault"
  value       = "Run: ./scripts/vault_init.sh"
}

output "api_access_instructions" {
  description = "Instructions to access Products API"
  value       = "kubectl -n data port-forward svc/products-api 8080:8080 then curl http://localhost:8080/products"
}

#############################################
# Bastion Host Outputs
#############################################

output "bastion_public_ip" {
  description = "Public IP address of the bastion host"
  value       = aws_instance.bastion.public_ip
}

output "bastion_ssh_command" {
  description = "SSH command to connect to bastion host"
  value       = "ssh -i .ssh/bastion-key.pem ec2-user@${aws_instance.bastion.public_ip}"
}

output "bastion_ssh_key_path" {
  description = "Path to SSH private key for bastion host"
  value       = abspath("${path.module}/../.ssh/bastion-key.pem")
}

output "bastion_access_instructions" {
  description = "Instructions to access API via bastion"
  value = <<-EOT
    1. SSH to bastion: ssh -i .ssh/bastion-key.pem ec2-user@${aws_instance.bastion.public_ip}
    2. Run helper script: ./test-api.sh
    3. Or manually port-forward: kubectl port-forward -n data svc/products-api 8080:8080
    4. Test API: curl http://localhost:8080/products
  EOT
}
