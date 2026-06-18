variable "project_name" {
  description = "Name used to prefix AWS resources for the challenge architecture."
  type        = string
  default     = "seazone-reservation-api"
}

variable "aws_region" {
  description = "AWS region for the target EKS architecture."
  type        = string
  default     = "us-east-1"
}

variable "kubernetes_version" {
  description = "Target Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.31"
}

variable "vpc_cidr" {
  description = "CIDR block for the challenge VPC."
  type        = string
  default     = "10.42.0.0/16"
}

variable "cluster_public_access_cidrs" {
  description = "Allowlist de CIDRs para o endpoint publico do API server. NUNCA usar 0.0.0.0/0 em producao. Placeholder sem dado real."
  type        = list(string)
  default     = ["10.0.0.0/8"]
}

variable "node_instance_types" {
  description = "Instance types do managed node group."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Quantidade desejada de worker nodes."
  type        = number
  default     = 2
}

variable "node_min_size" {
  description = "Minimo de worker nodes."
  type        = number
  default     = 2
}

variable "node_max_size" {
  description = "Maximo de worker nodes."
  type        = number
  default     = 4
}
