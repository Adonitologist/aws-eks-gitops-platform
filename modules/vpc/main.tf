locals {
  # Rule numbers are spaced by 10 so new rules can be inserted later.
  # Traffic inside the VPC is fully allowed; external traffic is limited to
  # HTTP/HTTPS and TCP ephemeral return ports. The VPC resolver (VPC+2) is not
  # filtered by NACLs, so no DNS rule is needed.
  private_inbound_acl_rules = [
    { rule_number = 100, rule_action = "allow", protocol = "-1", cidr_block = var.vpc_cidr },
    { rule_number = 110, rule_action = "allow", protocol = "tcp", from_port = 1024, to_port = 65535, cidr_block = "0.0.0.0/0" },
  ]

  private_outbound_acl_rules = [
    { rule_number = 100, rule_action = "allow", protocol = "-1", cidr_block = var.vpc_cidr },
    { rule_number = 110, rule_action = "allow", protocol = "tcp", from_port = 443, to_port = 443, cidr_block = "0.0.0.0/0" },
  ]

  public_inbound_acl_rules = [
    { rule_number = 100, rule_action = "allow", protocol = "-1", cidr_block = var.vpc_cidr },
    { rule_number = 110, rule_action = "allow", protocol = "tcp", from_port = 80, to_port = 80, cidr_block = "0.0.0.0/0" },
    { rule_number = 120, rule_action = "allow", protocol = "tcp", from_port = 443, to_port = 443, cidr_block = "0.0.0.0/0" },
    { rule_number = 130, rule_action = "allow", protocol = "tcp", from_port = 1024, to_port = 65535, cidr_block = "0.0.0.0/0" },
  ]

  public_outbound_acl_rules = [
    { rule_number = 100, rule_action = "allow", protocol = "-1", cidr_block = var.vpc_cidr },
    { rule_number = 110, rule_action = "allow", protocol = "tcp", from_port = 443, to_port = 443, cidr_block = "0.0.0.0/0" },
    { rule_number = 120, rule_action = "allow", protocol = "tcp", from_port = 1024, to_port = 65535, cidr_block = "0.0.0.0/0" },
  ]
}

# tfsec ignores (upstream module rules are not editable; justifications):
# - aws-ec2-no-excessive-port-access: allow-all applies only to the VPC CIDR. It is
#   required for pod, node and control plane traffic. Security groups are the primary control.
# - aws-ec2-no-public-ingress-acl: the internet-facing ALB requires 80/443 ingress from
#   0.0.0.0/0. NACLs are stateless, so NAT return traffic requires ephemeral 1024-65535
#   from 0.0.0.0/0.
# - aws-ec2-require-vpc-flow-logs-for-all-vpcs: aws_flow_log is created by the upstream
#   module (enable_flow_log = true) and confirmed in terraform plan; tfsec cannot resolve
#   its vpc_id through local.vpc_id.
#tfsec:ignore:aws-ec2-no-excessive-port-access
#tfsec:ignore:aws-ec2-no-public-ingress-acl
#tfsec:ignore:aws-ec2-require-vpc-flow-logs-for-all-vpcs
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "vpc-${var.cluster_name}"
  cidr = var.vpc_cidr

  azs             = var.azs
  private_subnets = [for k, az in var.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, az in var.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]

  enable_nat_gateway   = true
  single_nat_gateway   = true # Cost optimization; set to false for strict high availability
  enable_dns_hostnames = true
  enable_dns_support   = true

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_max_aggregation_interval               = 60
  flow_log_cloudwatch_log_group_retention_in_days = var.flow_log_retention_in_days

  public_dedicated_network_acl  = true
  private_dedicated_network_acl = true
  public_inbound_acl_rules      = local.public_inbound_acl_rules
  public_outbound_acl_rules     = local.public_outbound_acl_rules
  private_inbound_acl_rules     = local.private_inbound_acl_rules
  private_outbound_acl_rules    = local.private_outbound_acl_rules

  # Tags required by ALB/NLB subnet discovery
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  # Tags required by internal ALBs and Karpenter auto-discovery
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = 1
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }
}
