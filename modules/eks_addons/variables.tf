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

variable "vpc_cni_version" {
  description = "Versión del add-on administrado vpc-cni (debe ser compatible con la versión de Kubernetes del cluster; por defecto la versión por defecto de EKS 1.35)"
  type        = string
  default     = "v1.22.4-eksbuild.3"

  validation {
    condition     = length(trimspace(var.vpc_cni_version)) > 0
    error_message = "vpc_cni_version no puede estar vacío."
  }
}

variable "coredns_version" {
  description = "Versión del add-on administrado coredns (debe ser compatible con la versión de Kubernetes del cluster; por defecto la versión por defecto de EKS 1.35)"
  type        = string
  default     = "v1.13.2-eksbuild.31"

  validation {
    condition     = length(trimspace(var.coredns_version)) > 0
    error_message = "coredns_version no puede estar vacío."
  }
}

variable "kube_proxy_version" {
  description = "Versión del add-on administrado kube-proxy (debe ser compatible con la versión de Kubernetes del cluster; por defecto la versión por defecto de EKS 1.35)"
  type        = string
  default     = "v1.35.3-eksbuild.29"

  validation {
    condition     = length(trimspace(var.kube_proxy_version)) > 0
    error_message = "kube_proxy_version no puede estar vacío."
  }
}

variable "pod_identity_agent_version" {
  description = "Versión del add-on administrado eks-pod-identity-agent (debe ser compatible con la versión de Kubernetes del cluster; por defecto la versión por defecto de EKS 1.35)"
  type        = string
  default     = "v1.3.10-eksbuild.3"

  validation {
    condition     = length(trimspace(var.pod_identity_agent_version)) > 0
    error_message = "pod_identity_agent_version no puede estar vacío."
  }
}
