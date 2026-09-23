module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.0"

  cluster_name    = var.cluster_name
  cluster_version = "1.30"

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids

  cluster_endpoint_public_access = true

  # Activacion critica de OIDC para permitir IRSA (IAM Roles for Service Accounts)
  enable_irsa = true

  # Modernizacion de acceso (Reemplaza el aws-auth configmap)
  authentication_mode                      = "API_AND_CONFIG_MAP"
  enable_cluster_creator_admin_permissions = true

  # System Node Group: Base minima. Karpenter escalara el resto de cargas dinamicamente.
  eks_managed_node_groups = {
    system_components = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2

      # Etiquetas y taints para aislar los workloads de sistema
      labels = {
        "role" = "system"
      }
    }
  }

  # Etiquetas del cluster para la interoperabilidad con Karpenter
  tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
}