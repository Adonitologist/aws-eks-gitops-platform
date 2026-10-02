output "lb_role_arn" {
  description = "ARN of the IAM role (IRSA) for the AWS Load Balancer Controller"
  value       = module.lb_role.iam_role_arn
}

output "karpenter_queue_name" {
  description = "Name of the SQS interruption queue for Karpenter"
  value       = module.karpenter.queue_name
}

output "karpenter_node_role_name" {
  description = "Name of the IAM role for the EC2 nodes provisioned by Karpenter (referenced by the EC2NodeClass)"
  value       = module.karpenter.node_iam_role_name
}
