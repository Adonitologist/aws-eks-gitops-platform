output "vpc_id" {
  value       = module.vpc.vpc_id
  description = "ID of the main VPC"
}

output "private_subnet_ids" {
  value       = module.vpc.private_subnets
  description = "List of private subnet IDs for the EKS nodes"
}

output "public_subnet_ids" {
  value       = module.vpc.public_subnets
  description = "List of public subnet IDs for the load balancers"
}
