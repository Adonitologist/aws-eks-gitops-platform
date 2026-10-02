output "configure_kubectl" {
  description = "Command to configure local kubectl access to the EKS cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks_cluster.cluster_name}"
}

output "cluster_name" {
  description = "Name of the EKS cluster (consumed by stacks/cluster)"
  value       = module.eks_cluster.cluster_name
}

output "cluster_endpoint" {
  description = "Private API endpoint of the EKS cluster (consumed by stacks/cluster)"
  value       = module.eks_cluster.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64 CA certificate of the EKS cluster (public data, consumed by stacks/cluster)"
  value       = module.eks_cluster.cluster_certificate_authority_data
}

output "lb_role_arn" {
  description = "ARN of the IAM role (IRSA) for the AWS Load Balancer Controller (consumed by stacks/cluster)"
  value       = module.eks_addons.lb_role_arn
}

output "karpenter_queue_name" {
  description = "Name of the SQS interruption queue for Karpenter (consumed by stacks/cluster)"
  value       = module.eks_addons.karpenter_queue_name
}

output "karpenter_node_role_name" {
  description = "Name of the IAM role for the EC2 nodes provisioned by Karpenter (must match the EC2NodeClass role)"
  value       = module.eks_addons.karpenter_node_role_name
}
