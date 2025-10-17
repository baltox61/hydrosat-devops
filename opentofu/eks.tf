module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.24.1"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"
  subnet_ids      = concat(module.vpc.private_subnets, module.vpc.public_subnets)
  vpc_id          = module.vpc.vpc_id

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      desired_size   = var.desired_size
      min_size       = var.min_size
      max_size       = var.max_size
      subnet_ids     = module.vpc.private_subnets
    }
  }

  enable_irsa = true
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}
