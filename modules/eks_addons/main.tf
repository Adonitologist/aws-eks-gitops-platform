# 1. IAM Role for AWS Load Balancer Controller (IRSA)
module "lb_role" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.30"

  role_name                              = "aws-lb-ctrl-${var.cluster_name}"
  attach_load_balancer_controller_policy = true

  oidc_providers = {
    main = {
      provider_arn               = var.oidc_arn
      namespace_service_accounts = ["kube-system:aws-load-balancer-controller"]
    }
  }
}

# 3. IAM Roles and Infrastructure for Karpenter (Pod Identity & Node Roles)
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = var.cluster_name

  # EKS Pod Identity is the modern replacement for IRSA
  enable_pod_identity             = true
  create_pod_identity_association = true

  # IAM role for the EC2 nodes provisioned by Karpenter
  create_node_iam_role = true
  node_iam_role_name   = "karpenter-node-${var.cluster_name}"

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name = var.cluster_name
  addon_name   = "eks-pod-identity-agent"
}
