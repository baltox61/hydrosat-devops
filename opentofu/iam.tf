# Comprehensive IAM configuration for EKS cluster and workloads
# Includes: EKS cluster/node roles, IRSA roles for Dagster/API, OIDC provider

#############################################
# EKS Cluster IAM Role
#############################################

resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.cluster_name}-cluster-role"
  }
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSClusterPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEKSVPCResourceController" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.cluster.name
}

#############################################
# EKS Node IAM Role
#############################################

resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.cluster_name}-node-role"
  }
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_AmazonSSMManagedInstanceCore" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.node.name
}

#############################################
# OIDC Provider for IRSA
#############################################

data "tls_certificate" "cluster" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "cluster" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.cluster.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.cluster_name}-oidc-provider"
  }
}

#############################################
# Dagster IRSA Role (S3 Write Access)
#############################################

locals {
  # Service account name created by dagster-user-deployments Helm subchart
  dagster_sa_name      = "dagster-dagster-user-deployments-user-deployments"
  dagster_sa_namespace = var.dagster_namespace
}

data "aws_iam_policy_document" "dagster_s3" {
  statement {
    sid     = "S3WriteProducts"
    actions = ["s3:PutObject", "s3:PutObjectAcl", "s3:ListBucket", "s3:GetObject"]
    resources = [
      aws_s3_bucket.products.arn,
      "${aws_s3_bucket.products.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "dagster_s3" {
  name        = "${var.cluster_name}-dagster-s3"
  description = "Allow Dagster to write weather products to S3"
  policy      = data.aws_iam_policy_document.dagster_s3.json
}

module "iam_role_dagster" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name_prefix = "${var.cluster_name}-dagster"
  role_policy_arns = {
    dagster_s3 = aws_iam_policy.dagster_s3.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.cluster.arn
      namespace_service_accounts = ["${local.dagster_sa_namespace}:${local.dagster_sa_name}"]
    }
  }
}

#############################################
# API IRSA Role (S3 Read-Only Access)
#############################################

locals {
  api_sa_name      = "products-api"
  api_sa_namespace = var.dagster_namespace
}

data "aws_iam_policy_document" "api_s3_readonly" {
  statement {
    sid     = "S3ReadProducts"
    actions = ["s3:GetObject", "s3:ListBucket"]
    resources = [
      aws_s3_bucket.products.arn,
      "${aws_s3_bucket.products.arn}/*"
    ]
  }
}

resource "aws_iam_policy" "api_s3_readonly" {
  name        = "${var.cluster_name}-api-s3-readonly"
  description = "Allow API to read weather products from S3"
  policy      = data.aws_iam_policy_document.api_s3_readonly.json
}

module "iam_role_api" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "5.39.1"

  role_name_prefix = "${var.cluster_name}-api"
  role_policy_arns = {
    api_s3_readonly = aws_iam_policy.api_s3_readonly.arn
  }

  oidc_providers = {
    main = {
      provider_arn               = aws_iam_openid_connect_provider.cluster.arn
      namespace_service_accounts = ["${local.api_sa_namespace}:${local.api_sa_name}"]
    }
  }
}

# All outputs consolidated in outputs.tf
