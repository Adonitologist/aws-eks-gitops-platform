# Justification: nodes need egress to ECR, STS, public registries and AWS APIs for
# Karpenter. Internet egress is already restricted to TCP 443 by the private subnet
# NACLs. VPC endpoints are not adopted due to cost and public registry dependencies.
#tfsec:ignore:aws-ec2-no-public-egress-sgr
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31"

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  # Endpoint 100% privado. Sin exposicion a internet publica.
  cluster_endpoint_public_access  = false
  cluster_endpoint_private_access = true

  # Logs de auditoria y control plane activados
  cluster_enabled_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  enable_irsa = true

  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  eks_managed_node_groups = {
    system_components = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.micro"]
      min_size       = 3
      desired_size   = 4
      max_size       = 5

      # Subnets estrictamente privadas para los nodos de trabajo
      subnet_ids = var.subnet_ids
    }
  }

  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}
