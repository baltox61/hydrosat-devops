output "cluster_name"         { value = module.eks.cluster_name }
output "cluster_endpoint"     { value = module.eks.cluster_endpoint }
output "products_bucket"      { value = aws_s3_bucket.products.bucket }
output "dagster_web_url_hint" { value = "After LB is ready, open Dagit at http(s)://<dagster-webserver-EXTERNAL-IP>/" }
