output "cluster_name" {
  description = "Target EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS API server endpoint."
  value       = aws_eks_cluster.main.endpoint
}

output "vpc_id" {
  description = "Target VPC id."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet ids intended for worker nodes."
  value       = aws_subnet.private[*].id
}

output "oidc_provider_arn" {
  description = "ARN do OIDC provider para IRSA (anexar em trust policies de service accounts)."
  value       = aws_iam_openid_connect_provider.eks.arn
}

output "node_group_name" {
  description = "Managed node group name."
  value       = aws_eks_node_group.default.node_group_name
}
