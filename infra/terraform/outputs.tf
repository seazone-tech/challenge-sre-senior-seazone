output "cluster_name" {
  description = "Target EKS cluster name."
  value       = aws_eks_cluster.main.name
}

output "vpc_id" {
  description = "Target VPC id."
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "Private subnet ids intended for worker nodes."
  value       = aws_subnet.private[*].id
}
