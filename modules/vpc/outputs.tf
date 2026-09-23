output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID de la VPC principal"
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "Lista de IDs de subredes privadas para los nodos de EKS"
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnets
  description = "Lista de IDs de subredes públicas para los balanceadores de carga"
}