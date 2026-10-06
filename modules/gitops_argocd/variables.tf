variable "ingress_hostname" {
  description = "Hostname for the Argo CD ingress rule and Argo CD URLs. Empty (default) renders a rule without a host match, so the UI answers on the ALB DNS name."
  type        = string
  default     = ""

  validation {
    condition     = var.ingress_hostname == "" || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,}$", var.ingress_hostname))
    error_message = "ingress_hostname must be empty or a lowercase DNS name such as argocd.example.org."
  }
}
