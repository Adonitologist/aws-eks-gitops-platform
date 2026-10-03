terraform {
  required_version = ">= 1.5.0"
}

module "vpc" {
  source       = "../../modules/vpc"
  environment  = var.environment
  cluster_name = local.cluster_name
  vpc_cidr     = var.vpc_cidr
  azs          = var.azs
}

module "eks_cluster" {
  source       = "../../modules/eks_cluster"
  environment  = var.environment
  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids

  depends_on = [module.vpc]
}

module "eks_addons" {
  source       = "../../modules/eks_addons"
  cluster_name = module.eks_cluster.cluster_name
  oidc_url     = module.eks_cluster.oidc_provider_url
  oidc_arn     = module.eks_cluster.oidc_provider_arn

  depends_on = [module.eks_cluster]
}

module "stage2_runner" {
  source                    = "../../modules/stage2_runner"
  cluster_name              = module.eks_cluster.cluster_name
  vpc_id                    = module.vpc.vpc_id
  subnet_id                 = module.vpc.private_subnet_ids[0]
  cluster_security_group_id = module.eks_cluster.cluster_security_group_id
  state_bucket_name         = var.state_bucket_name

  tags = {
    Environment = var.environment
    Component   = "stage2-runner"
  }

  depends_on = [module.eks_cluster]
}

locals {
  cluster_name = "eks-gitops-${var.environment}"
}