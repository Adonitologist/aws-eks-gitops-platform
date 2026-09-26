module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.31" 

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access = true

  # Critical OIDC activation for IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Modern access management (Replaces aws-auth configmap)
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # System Node Group: Base minimal setup. Karpenter dynamically scales workloads.
  eks_managed_node_groups = {
    system_components = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.micro"] # Obligatorio por tu cuenta de AWS
      min_size       = 3
      desired_size   = 4 # Distribuimos la carga en 4 nodos pequeños
      max_size       = 5
    }
  }

  # Cluster tags for Karpenter interoperability
  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}