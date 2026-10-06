variable "ingress_hostname" {
  description = "Hostname for the Argo CD ingress rule and Argo CD URLs. Empty (default) renders a rule without a host match, so the UI answers on the ALB DNS name."
  type        = string
  default     = ""

  validation {
    condition     = var.ingress_hostname == "" || can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?[.])+[a-z]{2,}$", var.ingress_hostname))
    error_message = "ingress_hostname must be empty or a lowercase DNS name such as argocd.example.org."
  }
}

variable "allowed_cidrs" {
  description = "IPv4 CIDRs allowed to reach the Argo CD ALB (annotation alb.ingress.kubernetes.io/inbound-cidrs). Required; 0.0.0.0/0 is rejected."
  type        = list(string)

  validation {
    condition     = length(var.allowed_cidrs) > 0 && alltrue([for c in var.allowed_cidrs : can(cidrhost(c, 0)) && !strcontains(c, ":") && c != "0.0.0.0/0"])
    error_message = "allowed_cidrs must be a non-empty list of valid IPv4 CIDRs (for example 203.0.113.10/32) and must not contain 0.0.0.0/0."
  }
}
