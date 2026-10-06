variable "aws_region" {
  description = "Region of the EKS cluster and of the stage-1 state bucket"
  type        = string
  default     = "us-east-1"
}

variable "argocd_hostname" {
  description = "Hostname for the Argo CD ingress. Empty (default) means no host match, so the UI answers on the ALB DNS name; argocd-cm url is then https://."
  type        = string
  default     = ""
}
