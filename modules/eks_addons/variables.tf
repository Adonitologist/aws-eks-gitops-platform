variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "oidc_url" {
  description = "OIDC Provider URL for IRSA"
  type        = string
}

variable "oidc_arn" {
  description = "OIDC Provider ARN for IRSA"
  type        = string
}