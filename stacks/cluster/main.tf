data "terraform_remote_state" "infra" {
  backend = "s3"
  config = {
    bucket = "eks-gitops-tfstate-154932391641"
    key    = "eks-gitops-platform/terraform.tfstate"
    region = "us-east-1"
  }
}

# Fails the plan if stage 1 has not created the Pod Identity agent yet (Karpenter needs it)
data "aws_eks_addon" "pod_identity_agent" {
  cluster_name = data.terraform_remote_state.infra.outputs.cluster_name
  addon_name   = "eks-pod-identity-agent"
}

module "eks_addons_helm" {
  source               = "../../modules/eks_addons_helm"
  cluster_name         = data.terraform_remote_state.infra.outputs.cluster_name
  lb_role_arn          = data.terraform_remote_state.infra.outputs.lb_role_arn
  karpenter_queue_name = data.terraform_remote_state.infra.outputs.karpenter_queue_name

  depends_on = [data.aws_eks_addon.pod_identity_agent]
}

module "gitops_argocd" {
  source = "../../modules/gitops_argocd"

  depends_on = [module.eks_addons_helm]
}
