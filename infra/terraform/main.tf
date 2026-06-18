data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

data "aws_region" "current" {}

locals {
  tags = {
    Project     = var.project_name
    Environment = "challenge"
    ManagedBy   = "terraform"
  }
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name = "${var.project_name}-vpc"
  })
}

resource "aws_subnet" "public" {
  # checkov:skip=CKV_AWS_130:Subnet PUBLICA precisa de IP publico para o load balancer publico do EKS (papel da subnet). Os workloads/nodes ficam nas subnets privadas.
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.project_name}-public-${count.index + 1}"
    # Tags exigidas pelo EKS para descoberta de subnets de load balancer publico.
    "kubernetes.io/role/elb" = "1"
  })
}

resource "aws_subnet" "private" {
  count = 2

  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = merge(local.tags, {
    Name = "${var.project_name}-private-${count.index + 1}"
    # Worker nodes vivem em subnet PRIVADA; tag para load balancer interno.
    "kubernetes.io/role/internal-elb" = "1"
  })
}

# ------------------------------------------------------------------------------
# IAM do control plane do EKS.
# ------------------------------------------------------------------------------
resource "aws_iam_role" "eks_cluster" {
  name = "${var.project_name}-eks-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "eks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# ------------------------------------------------------------------------------
# KMS para envelope encryption dos secrets do Kubernetes (etcd).
# POR QUE: secrets no etcd sem KMS ficam apenas em base64. Hardening exigido em
# ambiente regulado (PCI/bancario). Achado tipico de Trivy/Checkov no estado original.
# ------------------------------------------------------------------------------
resource "aws_kms_key" "eks" {
  description             = "${var.project_name} EKS secrets envelope encryption"
  enable_key_rotation     = true
  deletion_window_in_days = 7

  # Key policy explicita (CKV2_AWS_64): acesso root da conta + permissao para o
  # CloudWatch Logs usar a chave (criptografia do log group de VPC Flow Logs).
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccount"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${data.aws_region.current.name}.amazonaws.com" }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = "*"
      }
    ]
  })

  tags = local.tags
}

# ------------------------------------------------------------------------------
# Cluster EKS — enderecando os gaps de seguranca do estado original:
#  - endpoint privado habilitado e publico restrito por CIDR (era 0.0.0.0/0);
#  - logs do control plane habilitados (auditoria);
#  - encryption_config para secrets.
# ------------------------------------------------------------------------------
resource "aws_eks_cluster" "main" {
  # checkov:skip=CKV_AWS_39:Endpoint publico restrito por allowlist de CIDR (var.cluster_public_access_cidrs) + endpoint privado habilitado. Acesso de gestao controlado, nunca exposto a 0.0.0.0/0.
  name     = var.project_name
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.kubernetes_version

  vpc_config {
    # Nodes ficam nas subnets privadas; control plane usa ambas para alta disponibilidade.
    subnet_ids              = concat(aws_subnet.public[*].id, aws_subnet.private[*].id)
    endpoint_public_access  = true
    endpoint_private_access = true
    # POR QUE: 0.0.0.0/0 expoe o API server para a internet inteira. Restringimos a
    # uma allowlist (VPN/escritorio/CIDR corporativo). Default placeholder, sem dado real.
    public_access_cidrs = var.cluster_public_access_cidrs
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = aws_kms_key.eks.arn
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy
  ]

  tags = local.tags
}

# ------------------------------------------------------------------------------
# IRSA — OIDC provider do cluster.
# POR QUE: permite que pods assumam IAM roles via service account (sem credencial
# estatica no container). Item obrigatorio da vaga e base de seguranca em EKS.
# ------------------------------------------------------------------------------
data "tls_certificate" "eks_oidc" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.main.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks_oidc.certificates[0].sha1_fingerprint]

  tags = local.tags
}

# ------------------------------------------------------------------------------
# IAM e managed node group (nas subnets privadas).
# POR QUE: o estado original nao tinha node group — um cluster sem worker nodes nao
# roda workload nenhum. Managed node group da upgrades/rotacao gerenciados pela AWS.
# ------------------------------------------------------------------------------
resource "aws_iam_role" "eks_nodes" {
  name = "${var.project_name}-eks-nodes"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "ec2.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "nodes" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.eks_nodes.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "default" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${var.project_name}-default"
  node_role_arn   = aws_iam_role.eks_nodes.arn
  subnet_ids      = aws_subnet.private[*].id
  instance_types  = var.node_instance_types

  scaling_config {
    desired_size = var.node_desired_size
    min_size     = var.node_min_size
    max_size     = var.node_max_size
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [
    aws_iam_role_policy_attachment.nodes
  ]

  tags = local.tags
}

# ------------------------------------------------------------------------------
# Default Security Group travado (CKV2_AWS_12).
# POR QUE: o SG default de toda VPC, se nao gerenciado, permite trafego entre si.
# Sem regras ingress/egress, ele bloqueia tudo e forca o uso de SGs explicitos.
# ------------------------------------------------------------------------------
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project_name}-default-locked" })
}

# ------------------------------------------------------------------------------
# VPC Flow Logs (CKV2_AWS_11): auditoria de trafego de rede da VPC.
# Destino: CloudWatch Logs com retencao de 1 ano e criptografia KMS.
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "vpc_flow" {
  name              = "/aws/vpc-flow-log/${var.project_name}"
  retention_in_days = 365
  kms_key_id        = aws_kms_key.eks.arn

  tags = local.tags
}

resource "aws_iam_role" "vpc_flow" {
  name = "${var.project_name}-vpc-flow-log"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "vpc-flow-logs.amazonaws.com" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "vpc_flow" {
  name = "${var.project_name}-vpc-flow-log"
  role = aws_iam_role.vpc_flow.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
        ]
        # Escopo restrito ao log group do flow log (sem wildcard de recurso).
        Resource = "${aws_cloudwatch_log_group.vpc_flow.arn}:*"
      }
    ]
  })
}

resource "aws_flow_log" "main" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "ALL"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc_flow.arn
  iam_role_arn         = aws_iam_role.vpc_flow.arn

  tags = local.tags
}
