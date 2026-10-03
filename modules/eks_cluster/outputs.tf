output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Name of the provisioned EKS cluster"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Control plane API endpoint"
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "ARN of the EKS OIDC provider"
}

output "oidc_provider_url" {
  value       = module.eks.cluster_oidc_issuer_url
  description = "URL of the OIDC issuer"
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Base64 certificate of the EKS cluster certificate authority (CA)"
}

output "cluster_security_group_id" {
  value       = module.eks.cluster_security_group_id
  description = "ID of the security group that controls access to the private API endpoint (attached to the control plane network interfaces)"
}