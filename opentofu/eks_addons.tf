#############################################
# EKS Addons
#############################################

# EBS CSI Driver IAM Role (required for EBS CSI addon)
data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.cluster.arn]
    }

    actions = ["sts:AssumeRoleWithWebIdentity"]

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:sub"
      values   = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
    }

    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${var.cluster_name}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role.json

  tags = {
    Name = "${var.cluster_name}-ebs-csi-driver"
  }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver" {
  role       = aws_iam_role.ebs_csi_driver.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Kube-proxy addon
resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "kube-proxy"
  addon_version               = "v1.33.3-eksbuild.10"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.cluster_name}-kube-proxy"
  }

  depends_on = [
    aws_eks_node_group.default
  ]
}

# CoreDNS addon
resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  addon_version               = "v1.12.4-eksbuild.1"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.cluster_name}-coredns"
  }

  depends_on = [
    aws_eks_node_group.default
  ]
}

# VPC CNI addon
resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "vpc-cni"
  addon_version               = "v1.20.3-eksbuild.1"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = {
    Name = "${var.cluster_name}-vpc-cni"
  }

  depends_on = [
    aws_eks_node_group.default
  ]
}

# EBS CSI Driver addon (required for persistent volumes)
resource "aws_eks_addon" "ebs_csi_driver" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = "v1.49.0-eksbuild.1"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn

  tags = {
    Name = "${var.cluster_name}-ebs-csi-driver"
  }

  depends_on = [
    aws_eks_node_group.default
  ]
}
