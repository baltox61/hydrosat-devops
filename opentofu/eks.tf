# EKS Cluster with raw resources (no module)
# Pattern based on production-grade approach using aws_eks_cluster + aws_eks_node_group
# IAM roles are defined in iam.tf
# Security Groups are defined in security.tf

#############################################
# EKS Cluster
#############################################

locals {
  node_group_name = "${var.cluster_name}-default"
}

resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = "1.33"

  vpc_config {
    subnet_ids              = concat(module.vpc.private_subnets, module.vpc.public_subnets)
    endpoint_private_access = true
    endpoint_public_access  = true
    security_group_ids      = [aws_security_group.cluster.id]
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_AmazonEKSClusterPolicy,
    aws_iam_role_policy_attachment.cluster_AmazonEKSVPCResourceController,
  ]
}

#############################################
# EKS Node Group
#############################################
# Node sizing for demo workload:
# - Base node group provides stable capacity for core services
# - Karpenter handles dynamic workloads with optimal instance selection
# - Min/desired/max sizing allows cost optimization during idle periods
# - Multi-AZ distribution for high availability demonstration

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = local.node_group_name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = module.vpc.private_subnets

  version        = "1.33"
  instance_types = var.node_instance_types
  capacity_type  = "ON_DEMAND"
  ami_type       = "AL2023_x86_64_STANDARD"

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  tags = {
    Name = local.node_group_name
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      scaling_config[0].desired_size,
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_AmazonEKSWorkerNodePolicy,
    aws_iam_role_policy_attachment.node_AmazonEKS_CNI_Policy,
    aws_iam_role_policy_attachment.node_AmazonEC2ContainerRegistryReadOnly,
  ]
}

# Optional: aws_autoscaling_attachment for external load balancer integration
# resource "aws_autoscaling_attachment" "alb" {
#   for_each = toset(var.lb_target_group_arns)
#
#   autoscaling_group_name = aws_eks_node_group.default.resources[0].autoscaling_groups[0].name
#   lb_target_group_arn    = each.value
# }

#############################################
# Cluster Authentication
#############################################

data "aws_eks_cluster_auth" "this" {
  name = aws_eks_cluster.this.name
}

# All outputs consolidated in outputs.tf
