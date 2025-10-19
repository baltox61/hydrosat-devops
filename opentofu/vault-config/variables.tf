# Variables for Vault configuration
# These should match the parent opentofu directory

variable "cluster_name" {
  type        = string
  default     = "dagster-eks"
  description = "Name of the EKS cluster"
}

variable "region" {
  type        = string
  default     = "us-east-2"
  description = "AWS region"
}
