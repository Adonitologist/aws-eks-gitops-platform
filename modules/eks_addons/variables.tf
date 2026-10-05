variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "oidc_arn" {
  description = "OIDC Provider ARN for IRSA"
  type        = string
}

variable "vpc_cni_version" {
  description = "Managed add-on version for vpc-cni (must be compatible with the cluster Kubernetes version; default is the EKS 1.35 default version)"
  type        = string
  default     = "v1.22.4-eksbuild.3"

  validation {
    condition     = length(trimspace(var.vpc_cni_version)) > 0
    error_message = "vpc_cni_version must not be empty."
  }
}

variable "coredns_version" {
  description = "Managed add-on version for coredns (must be compatible with the cluster Kubernetes version; default is the EKS 1.35 default version)"
  type        = string
  default     = "v1.13.2-eksbuild.31"

  validation {
    condition     = length(trimspace(var.coredns_version)) > 0
    error_message = "coredns_version must not be empty."
  }
}

variable "kube_proxy_version" {
  description = "Managed add-on version for kube-proxy (must be compatible with the cluster Kubernetes version; default is the EKS 1.35 default version)"
  type        = string
  default     = "v1.35.3-eksbuild.29"

  validation {
    condition     = length(trimspace(var.kube_proxy_version)) > 0
    error_message = "kube_proxy_version must not be empty."
  }
}

variable "pod_identity_agent_version" {
  description = "Managed add-on version for eks-pod-identity-agent (must be compatible with the cluster Kubernetes version; default is the EKS 1.35 default version)"
  type        = string
  default     = "v1.3.10-eksbuild.3"

  validation {
    condition     = length(trimspace(var.pod_identity_agent_version)) > 0
    error_message = "pod_identity_agent_version must not be empty."
  }
}
