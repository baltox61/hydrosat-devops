terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.50"
    }
    vault = {
      source  = "hashicorp/vault"
      version = ">= 3.0"
    }
  }
}

# AWS provider for querying EKS cluster info
provider "aws" {
  region = var.region
}

# Vault provider configuration
# Address and token should be set via environment variables:
#   - VAULT_ADDR (set to http://127.0.0.1:8200 via port-forward)
#   - VAULT_TOKEN (from vault_init.sh)
provider "vault" {
  # VAULT_ADDR environment variable takes precedence
  # During deployment: uses port-forward to localhost:8200
  skip_child_token = true
}
