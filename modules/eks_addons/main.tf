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

data "aws_region" "current" {}

# Actions required by Karpenter v1.14.1 that module v20.37.2 does not yet grant
# (source: v1.14.1 getting-started cloudformation.yaml)
# Wildcard resource on iam:ListInstanceProfiles is intentional: upstream Karpenter grants it unscoped
#tfsec:ignore:aws-iam-no-policy-wildcards
data "aws_iam_policy_document" "karpenter_controller_extra" {
  statement {
    sid       = "AllowRegionalReadActionsExtra"
    effect    = "Allow"
    actions   = ["ec2:DescribeCapacityReservations", "ec2:DescribeInstanceStatus", "ec2:DescribePlacementGroups"]
    resources = ["*"] # EC2 Describe* actions do not support resource-level permissions

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [data.aws_region.current.name]
    }
  }

  statement {
    sid       = "AllowUnscopedInstanceProfileListAction"
    effect    = "Allow"
    actions   = ["iam:ListInstanceProfiles"]
    resources = ["*"] # iam:ListInstanceProfiles does not support resource-level permissions
  }
}

resource "aws_iam_policy" "karpenter_controller_extra" {
  name        = "karpenter-controller-extra-${var.cluster_name}"
  description = "Extra Karpenter v1.14.1 controller permissions missing from the module policy"
  policy      = data.aws_iam_policy_document.karpenter_controller_extra.json
}

# 3. IAM Roles and Infrastructure for Karpenter (Pod Identity & Node Roles)
module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "~> 20.0"

  cluster_name = var.cluster_name

  # EKS Pod Identity is the modern replacement for IRSA
  enable_pod_identity             = true
  create_pod_identity_association = true

  # Permissions for Karpenter v1.x; the module default (false) is the v0.33-v0.37 policy
  enable_v1_permissions = true

  # Extra permissions live in a separate managed policy because the module policy alone
  # is close to the 6144-character managed policy limit
  iam_role_policies = {
    extra = aws_iam_policy.karpenter_controller_extra.arn
  }

  # IAM role for the EC2 nodes provisioned by Karpenter. The exact name (no random suffix)
  # is referenced by the EC2NodeClass in kubernetes/workloads/karpenter-nodepool.yaml
  create_node_iam_role          = true
  node_iam_role_name            = "karpenter-node-${var.cluster_name}"
  node_iam_role_use_name_prefix = false

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}

# 4. EKS managed add-ons with pinned versions. Created through the EKS API, so the private
# cluster endpoint is not needed. The caller (stacks/infra) creates them after the cluster
# and its managed node group, which CoreDNS needs in order to become ACTIVE.
locals {
  managed_addons = {
    "vpc-cni"                = var.vpc_cni_version
    "coredns"                = var.coredns_version
    "kube-proxy"             = var.kube_proxy_version
    "eks-pod-identity-agent" = var.pod_identity_agent_version
  }
}

resource "aws_eks_addon" "managed" {
  for_each = local.managed_addons

  cluster_name  = var.cluster_name
  addon_name    = each.key
  addon_version = each.value

  # The cluster bootstraps self-managed vpc-cni, kube-proxy and CoreDNS by default
  # (bootstrap_self_managed_addons is left unset), so adopting them as managed add-ons needs
  # OVERWRITE on create; with NONE the create fails on field conflicts. OVERWRITE on update
  # keeps the add-on equal to the pinned version and configuration, reverting manual edits.
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}
