output "lb_role_arn" {
  description = "ARN of the IAM role (IRSA) for the AWS Load Balancer Controller"
  value       = module.lb_role.iam_role_arn
}

output "karpenter_queue_name" {
  description = "Name of the SQS interruption queue for Karpenter"
  value       = module.karpenter.queue_name
}
