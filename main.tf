terraform {
  required_version = ">= 1.5.0"
}

module "vpc" {
  source       = "./modules/vpc"
  environment  = var.environment
  cluster_name = local.cluster_name
  vpc_cidr     = var.vpc_cidr
  azs          = var.azs
}

module "eks_cluster" {
  source       = "./modules/eks_cluster"
  environment  = var.environment
  cluster_name = local.cluster_name
  vpc_id       = module.vpc.vpc_id
  subnet_ids   = module.vpc.private_subnet_ids

  depends_on = [module.vpc]
}

module "eks_addons" {
  source       = "./modules/eks_addons"
  cluster_name = module.eks_cluster.cluster_name
  oidc_url     = module.eks_cluster.oidc_provider_url
  oidc_arn     = module.eks_cluster.oidc_provider_arn

  depends_on = [module.eks_cluster]
}

module "eks_addons_helm" {
  source               = "./modules/eks_addons_helm"
  cluster_name         = module.eks_cluster.cluster_name
  lb_role_arn          = module.eks_addons.lb_role_arn
  karpenter_queue_name = module.eks_addons.karpenter_queue_name

  # Karpenter needs the Pod Identity agent (created in eks_addons) before it starts
  depends_on = [module.eks_addons]
}

module "gitops_argocd" {
  source       = "./modules/gitops_argocd"
  cluster_name = module.eks_cluster.cluster_name

  depends_on = [module.eks_addons_helm]
}

locals {
  cluster_name = "eks-gitops-${var.environment}"
}