resource "kubernetes_namespace" "karpenter" {
  metadata {
    name = "karpenter"
  }
}

data "aws_iam_policy_document" "karpenter_controller_assume_role" {
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
      values   = ["system:serviceaccount:karpenter:karpenter"]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "karpenter_controller" {
  name               = "${var.cluster_name}-karpenter-controller"
  assume_role_policy = data.aws_iam_policy_document.karpenter_controller_assume_role.json

  tags = {
    Name = "${var.cluster_name}-karpenter-controller"
  }
}

data "aws_iam_policy_document" "karpenter_controller" {
  # EC2 permissions for provisioning/terminating instances
  statement {
    sid = "EC2Management"
    actions = [
      "ec2:CreateFleet",
      "ec2:CreateLaunchTemplate",
      "ec2:CreateTags",
      "ec2:DescribeAvailabilityZones",
      "ec2:DescribeImages",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceTypeOfferings",
      "ec2:DescribeInstanceTypes",
      "ec2:DescribeLaunchTemplates",
      "ec2:DescribeSecurityGroups",
      "ec2:DescribeSpotPriceHistory",
      "ec2:DescribeSubnets",
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:DeleteLaunchTemplate"
    ]
    resources = ["*"]
  }

  # IAM permissions to pass node role to instances
  statement {
    sid       = "PassNodeRole"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.karpenter_node.arn]
  }

  # IAM permissions for instance profiles
  statement {
    sid = "InstanceProfileManagement"
    actions = [
      "iam:CreateInstanceProfile",
      "iam:DeleteInstanceProfile",
      "iam:GetInstanceProfile",
      "iam:TagInstanceProfile",
      "iam:AddRoleToInstanceProfile",
      "iam:RemoveRoleFromInstanceProfile"
    ]
    resources = ["*"]
  }

  # Pricing API for cost-aware instance selection
  statement {
    sid       = "PricingAPI"
    actions   = ["pricing:GetProducts"]
    resources = ["*"]
  }

  # SSM for retrieving AMI IDs
  statement {
    sid       = "SSM"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${var.region}::parameter/aws/service/*"]
  }

  # EKS cluster access
  statement {
    sid = "EKSClusterAccess"
    actions = [
      "eks:DescribeCluster"
    ]
    resources = [aws_eks_cluster.this.arn]
  }

  # SQS for interruption handling (Spot instances)
  statement {
    sid = "InterruptionQueue"
    actions = [
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
      "sqs:ReceiveMessage"
    ]
    resources = [aws_sqs_queue.karpenter_interruption.arn]
  }
}

resource "aws_iam_policy" "karpenter_controller" {
  name        = "${var.cluster_name}-karpenter-controller"
  description = "Karpenter controller policy for ${var.cluster_name}"
  policy      = data.aws_iam_policy_document.karpenter_controller.json
}

resource "aws_iam_role_policy_attachment" "karpenter_controller" {
  role       = aws_iam_role.karpenter_controller.name
  policy_arn = aws_iam_policy.karpenter_controller.arn
}

resource "aws_iam_role" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"

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
    Name = "${var.cluster_name}-karpenter-node"
  }
}

# Attach standard EKS node policies
resource "aws_iam_role_policy_attachment" "karpenter_node_AmazonEKSWorkerNodePolicy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_AmazonEKS_CNI_Policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_AmazonEC2ContainerRegistryReadOnly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.karpenter_node.name
}

resource "aws_iam_role_policy_attachment" "karpenter_node_AmazonSSMManagedInstanceCore" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.karpenter_node.name
}

# Create instance profile for Karpenter nodes
resource "aws_iam_instance_profile" "karpenter_node" {
  name = "${var.cluster_name}-karpenter-node"
  role = aws_iam_role.karpenter_node.name

  tags = {
    Name = "${var.cluster_name}-karpenter-node"
  }
}

# SQS Queue for Spot Interruption Handling
resource "aws_sqs_queue" "karpenter_interruption" {
  name                      = "${var.cluster_name}-karpenter-interruption"
  message_retention_seconds = 300
  sqs_managed_sse_enabled   = true

  tags = {
    Name = "${var.cluster_name}-karpenter-interruption"
  }
}

resource "aws_sqs_queue_policy" "karpenter_interruption" {
  queue_url = aws_sqs_queue.karpenter_interruption.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = [
            "events.amazonaws.com",
            "sqs.amazonaws.com"
          ]
        }
        Action   = "sqs:SendMessage"
        Resource = aws_sqs_queue.karpenter_interruption.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "${var.cluster_name}-karpenter-spot-interruption"
  description = "Capture EC2 Spot Instance interruption warnings"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Spot Instance Interruption Warning"]
  })

  tags = {
    Name = "${var.cluster_name}-spot-interruption"
  }
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# EC2 Instance Rebalance Recommendation
resource "aws_cloudwatch_event_rule" "rebalance_recommendation" {
  name        = "${var.cluster_name}-karpenter-rebalance"
  description = "Capture EC2 rebalance recommendations"

  event_pattern = jsonencode({
    source      = ["aws.ec2"]
    detail-type = ["EC2 Instance Rebalance Recommendation"]
  })

  tags = {
    Name = "${var.cluster_name}-rebalance"
  }
}

resource "aws_cloudwatch_event_target" "rebalance_recommendation" {
  rule      = aws_cloudwatch_event_rule.rebalance_recommendation.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

# Scheduled Instance Change
resource "aws_cloudwatch_event_rule" "scheduled_change" {
  name        = "${var.cluster_name}-karpenter-scheduled-change"
  description = "Capture EC2 scheduled instance changes"

  event_pattern = jsonencode({
    source      = ["aws.health"]
    detail-type = ["AWS Health Event"]
  })

  tags = {
    Name = "${var.cluster_name}-scheduled-change"
  }
}

resource "aws_cloudwatch_event_target" "scheduled_change" {
  rule      = aws_cloudwatch_event_rule.scheduled_change.name
  target_id = "KarpenterInterruptionQueue"
  arn       = aws_sqs_queue.karpenter_interruption.arn
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = "1.5.0"
  namespace  = kubernetes_namespace.karpenter.metadata[0].name
  wait       = true

  values = [yamlencode({
    settings = {
      clusterName     = var.cluster_name
      clusterEndpoint = aws_eks_cluster.this.endpoint
      interruptionQueue = aws_sqs_queue.karpenter_interruption.name
    }

    serviceAccount = {
      annotations = {
        "eks.amazonaws.com/role-arn" = aws_iam_role.karpenter_controller.arn
      }
    }

    # Controller replicas for HA (set to 1 for demo, 2+ for production)
    replicas = 1

    # Resource requests/limits (Karpenter is lightweight)
    resources = {
      requests = {
        cpu    = "100m"
        memory = "256Mi"
      }
      limits = {
        cpu    = "1000m"
        memory = "1Gi"
      }
    }

    # Pod disruption budget for HA
    podDisruptionBudget = {
      maxUnavailable = 1
    }
  })]

  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role.karpenter_controller,
    aws_iam_instance_profile.karpenter_node,
    aws_sqs_queue.karpenter_interruption
  ]
}

# Default NodePool for general workloads
resource "kubectl_manifest" "karpenter_nodepool_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "default"
    }
    spec = {
      # Template for node configuration
      template = {
        metadata = {
          labels = {
            "workload-type" = "general"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          # Requirements for instance selection
          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot", "on-demand"] # Prefer Spot, fallback to On-Demand
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r", "t"] # Compute, General, Memory, Burstable
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"] # Only 5th gen or newer (c5, m5, t3, etc.)
            }
          ]

          # Taints for workload isolation (none for default pool)
          taints = []
        }
      }

      # Limits to prevent runaway scaling
      limits = {
        cpu    = "100"
        memory = "200Gi"
      }

      # Disruption budget for graceful node termination
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "30s"
        budgets = [
          {
            nodes = "10%"
          }
        ]
      }
    }
  })

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.karpenter_ec2nodeclass_default
  ]
}

# NodePool for batch jobs (Spot-only, aggressive consolidation)
resource "kubectl_manifest" "karpenter_nodepool_batch" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata = {
      name = "batch"
    }
    spec = {
      template = {
        metadata = {
          labels = {
            "workload-type" = "batch"
          }
        }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = "default"
          }

          requirements = [
            {
              key      = "karpenter.sh/capacity-type"
              operator = "In"
              values   = ["spot"] # Spot only for cost savings
            },
            {
              key      = "kubernetes.io/arch"
              operator = "In"
              values   = ["amd64"]
            },
            {
              key      = "karpenter.k8s.aws/instance-category"
              operator = "In"
              values   = ["c", "m", "r"] # Compute-optimized for data processing
            },
            {
              key      = "karpenter.k8s.aws/instance-generation"
              operator = "Gt"
              values   = ["4"]
            }
          ]

          taints = [
            {
              key    = "workload-type"
              value  = "batch"
              effect = "NoSchedule"
            }
          ]
        }
      }

      limits = {
        cpu    = "200"
        memory = "400Gi"
      }

      disruption = {
        consolidationPolicy = "WhenEmpty"
        consolidateAfter    = "10s" # Aggressive termination for batch jobs
      }
    }
  })

  depends_on = [
    helm_release.karpenter,
    kubectl_manifest.karpenter_ec2nodeclass_default
  ]
}

resource "kubectl_manifest" "karpenter_ec2nodeclass_default" {
  yaml_body = yamlencode({
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata = {
      name = "default"
    }
    spec = {
      # AMI selection (EKS optimized)
      amiSelectorTerms = [
        {
          alias = "al2023@latest" # Amazon Linux 2023 (latest EKS-optimized)
        }
      ]

      # IAM instance profile
      role = aws_iam_role.karpenter_node.name

      # Subnet selection (use cluster's private subnets)
      subnetSelectorTerms = [
        {
          tags = {
            "kubernetes.io/cluster/${var.cluster_name}" = "owned"
            "kubernetes.io/role/internal-elb"            = "1"
          }
        }
      ]

      # Security group selection
      securityGroupSelectorTerms = [
        {
          tags = {
            "kubernetes.io/cluster/${var.cluster_name}" = "owned"
          }
        }
      ]

      # User data for node bootstrap
      userData = <<-EOT
        #!/bin/bash
        /etc/eks/bootstrap.sh ${var.cluster_name}
      EOT

      # Tags applied to EC2 instances
      tags = {
        Name                     = "${var.cluster_name}-karpenter-node"
        "karpenter.sh/discovery" = var.cluster_name
        ManagedBy                = "karpenter"
      }

      # Block device mappings
      blockDeviceMappings = [
        {
          deviceName = "/dev/xvda"
          ebs = {
            volumeSize          = "50Gi"
            volumeType          = "gp3"
            encrypted           = true
            deleteOnTermination = true
          }
        }
      ]

      # Metadata options (IMDSv2 required for security)
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpProtocolIPv6        = "disabled"
        httpPutResponseHopLimit = 2
        httpTokens              = "required" # Require IMDSv2
      }
    }
  })

  depends_on = [
    helm_release.karpenter
  ]
}
