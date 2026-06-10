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
