# Justification: nodes need egress to ECR, STS, public registries and AWS APIs for
# Karpenter. Internet egress is already restricted to TCP 443 by the private subnet
# NACLs. VPC endpoints are not adopted due to cost and public registry dependencies.
#trivy:ignore:AVD-AWS-0104
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # 100% private endpoint. No exposure to the public internet.
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  # Audit and control plane logs enabled
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  enable_irsa = true

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    system_components = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = var.system_node_instance_types
      min_size       = var.system_node_min_size
      desired_size   = var.system_node_desired_size
      max_size       = var.system_node_max_size

      # Strictly private subnets for the worker nodes
      subnet_ids = var.subnet_ids
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
