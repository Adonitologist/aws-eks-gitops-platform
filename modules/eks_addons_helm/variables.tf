variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "lb_role_arn" {
  description = "ARN of the IAM role (IRSA) used by the AWS Load Balancer Controller service account"
  type        = string
}

variable "karpenter_queue_name" {
  description = "Name of the SQS interruption queue consumed by Karpenter"
  type        = string
}
