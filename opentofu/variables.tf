variable "region"         { type = string  default = "us-east-2" }
variable "cluster_name"   { type = string  default = "dagster-eks" }
variable "vpc_cidr"       { type = string  default = "10.42.0.0/16" }
variable "public_subnets" { type = list(string) default = ["10.42.1.0/24","10.42.2.0/24"] }
variable "private_subnets"{ type = list(string) default = ["10.42.101.0/24","10.42.102.0/24"] }

variable "node_instance_types" { type = list(string) default = ["t3.large"] }
variable "desired_size"        { type = number default = 2 }
variable "min_size"            { type = number default = 2 }
variable "max_size"            { type = number default = 5 }

variable "products_bucket"     { type = string  default = "dagster-weather-products" }
variable "dagster_namespace"   { type = string  default = "data" }
variable "monitoring_namespace"{ type = string  default = "monitoring" }

variable "openweather_api_key" { type = string  sensitive = true }
