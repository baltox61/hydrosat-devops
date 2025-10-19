# Bastion Host for secure access to EKS cluster
# Deployed in public subnet to allow SSH access from internet
# Used to demonstrate that API is only accessible via bastion

#############################################
# Security Group for Bastion Host
#############################################

resource "aws_security_group" "bastion" {
  name_prefix = "${var.cluster_name}-bastion-"
  description = "Security group for bastion host"
  vpc_id      = module.vpc.vpc_id

  # Allow SSH from anywhere (restrict this to your IP in production)
  ingress {
    description = "SSH from anywhere"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-bastion-sg"
  }
}

#############################################
# IAM Role for Bastion Host
#############################################

resource "aws_iam_role" "bastion" {
  name = "${var.cluster_name}-bastion-role"

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
    Name = "${var.cluster_name}-bastion-role"
  }
}

# Policy to allow bastion to access EKS cluster
resource "aws_iam_role_policy" "bastion_eks_access" {
  name = "${var.cluster_name}-bastion-eks-access"
  role = aws_iam_role.bastion.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "eks:DescribeCluster",
          "eks:ListClusters"
        ]
        Resource = "*"
      }
    ]
  })
}

# Attach SSM policy for session manager access (alternative to SSH)
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.cluster_name}-bastion-profile"
  role = aws_iam_role.bastion.name

  tags = {
    Name = "${var.cluster_name}-bastion-profile"
  }
}

#############################################
# SSH Key Pair for Bastion
#############################################

# Generate SSH key pair locally
resource "tls_private_key" "bastion" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "bastion" {
  key_name   = "${var.cluster_name}-bastion-key"
  public_key = tls_private_key.bastion.public_key_openssh

  tags = {
    Name = "${var.cluster_name}-bastion-key"
  }
}

# Save private key locally
resource "local_file" "bastion_private_key" {
  content         = tls_private_key.bastion.private_key_pem
  filename        = "${path.module}/../.ssh/bastion-key.pem"
  file_permission = "0600"
}

#############################################
# Get Latest Amazon Linux 2023 AMI
#############################################

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#############################################
# Bastion EC2 Instance
#############################################

resource "aws_instance" "bastion" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.bastion.key_name
  subnet_id                   = module.vpc.public_subnets[0]
  vpc_security_group_ids      = [aws_security_group.bastion.id]
  iam_instance_profile        = aws_iam_instance_profile.bastion.name
  associate_public_ip_address = true

  # User data to install kubectl and configure EKS access
  user_data_base64 = base64encode(templatefile("${path.module}/bastion-userdata.sh", {
    cluster_name = var.cluster_name
    region       = var.region
  }))

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    delete_on_termination = true
  }

  tags = {
    Name = "${var.cluster_name}-bastion"
  }

  depends_on = [
    aws_eks_cluster.this
  ]
}

#############################################
# Update EKS aws-auth ConfigMap
#############################################

# Use kubectl provider to patch the existing aws-auth ConfigMap
# This is safer than managing the entire ConfigMap with kubernetes provider
resource "kubectl_manifest" "aws_auth_bastion" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: ConfigMap
    metadata:
      name: aws-auth
      namespace: kube-system
    data:
      mapRoles: |
        - rolearn: ${aws_iam_role.node.arn}
          username: system:node:{{EC2PrivateDNSName}}
          groups:
          - system:bootstrappers
          - system:nodes
        - rolearn: ${aws_iam_role.karpenter_node.arn}
          username: system:node:{{EC2PrivateDNSName}}
          groups:
          - system:bootstrappers
          - system:nodes
        - rolearn: ${aws_iam_role.bastion.arn}
          username: bastion-user
          groups:
          - system:masters
  YAML

  depends_on = [
    aws_eks_node_group.default,
    aws_iam_role.bastion
  ]
}
