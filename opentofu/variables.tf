variable "region" {
  type    = string
  default = "us-east-2"
}

variable "cluster_name" {
  type    = string
  default = "dagster-eks"
}

variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}

variable "public_subnets" {
  type    = list(string)
  default = ["10.42.1.0/24", "10.42.2.0/24"]
}

variable "private_subnets" {
  type    = list(string)
  default = ["10.42.101.0/24", "10.42.102.0/24"]
}

variable "node_instance_types" {
  type        = list(string)
  default     = ["t3.medium"]
  description = "Instance types for base node group (t3.medium = 2 vCPU, 4GB RAM, sufficient for demo workload)"
}

variable "desired_size" {
  type    = number
  default = 2
}

variable "min_size" {
  type        = number
  default     = 1
  description = "Minimum number of nodes (allows Cluster Autoscaler to scale down to 1)"
}

variable "max_size" {
  type    = number
  default = 5
}

variable "products_bucket" {
  type    = string
  default = "dagster-weather-products"
}

variable "dagster_namespace" {
  type    = string
  default = "data"
}

variable "monitoring_namespace" {
  type    = string
  default = "monitoring"
}

# OpenWeather API key is NOT stored in Terraform variables for security
# Instead, it's stored directly in Vault via ./scripts/vault_init.sh
# Applications fetch it at runtime via Vault init container

# Database password
variable "dagster_db_password" {
  type        = string
  sensitive   = true
  default     = "changeme-dagster-password"
  description = "PostgreSQL password for Dagster metadata database"
}

# Monitoring/Alerting
variable "slack_webhook_url" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Slack webhook URL for AlertManager notifications (optional)"
}

# Docker image configuration
variable "dagster_image_repository" {
  type        = string
  description = "Docker image repository for Dagster user code (e.g., 123456789012.dkr.ecr.us-east-2.amazonaws.com/dagster-weather-app)"
}

variable "dagster_image_tag" {
  type        = string
  default     = "latest"
  description = "Docker image tag for Dagster user code"
}

variable "api_image" {
  type        = string
  description = "Full Docker image path for FastAPI (e.g., 123456789012.dkr.ecr.us-east-2.amazonaws.com/weather-products-api:latest)"
}
