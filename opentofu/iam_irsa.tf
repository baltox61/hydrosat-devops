locals {
  dagster_sa_name      = "dagster-user-code"
  dagster_sa_namespace = var.dagster_namespace
}

data "aws_iam_policy_document" "dagster_s3" {
  statement {
    sid     = "S3WriteProducts"
    actions = ["s3:PutObject","s3:PutObjectAcl","s3:ListBucket","s3:GetObject"]
    resources = [
      aws_s3_bucket.products.arn,
      "${aws_s3_bucket.products.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "dagster_s3" {
  name   = "${var.cluster_name}-dagster-s3"
  policy = data.aws_iam_policy_document.dagster_s3.json
}

module "iam_role_dagster" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name_prefix    = "${var.cluster_name}-dagster"
  attach_policy_jsons = [aws_iam_policy.dagster_s3.policy]

  oidc_providers = {
    main = {
      provider_arn                = module.eks.oidc_provider_arn
      namespace_service_accounts  = ["${local.dagster_sa_namespace}:${local.dagster_sa_name}"]
    }
  }
}
