output "cluster_name" {
  value       = module.eks.cluster_name
  description = "Nombre del cluster EKS aprovisionado"
}

output "cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Endpoint de la API del plano de control"
}

output "oidc_provider_arn" {
  value       = module.eks.oidc_provider_arn
  description = "ARN del proveedor OIDC de EKS"
}

output "oidc_provider_url" {
  value       = module.eks.cluster_oidc_issuer_url
  description = "URL del emisor OIDC"
}

output "cluster_certificate_authority_data" {
  value       = module.eks.cluster_certificate_authority_data
  description = "Certificado Base64 de la Autoridad Certificadora (CA) del cluster EKS"
}