locals {
  name         = "${var.cluster_name}-stage2-runner"
  state_prefix = dirname(var.cluster_state_key)

  # Document names allow 3 to 128 characters of [a-zA-Z0-9_.-] and cannot start with aws, amazon or
  # amzn (CreateDocument API reference); var.cluster_name is validated for the reserved prefixes
  session_document_name = "${local.name}-session"

  # Access policy ARNs are AWS-defined constants (partition aws, no account or Region)
  cluster_admin_policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# Public AWS parameter; the AMI is resolved when the plan is made. The instance ignores later AMI
# changes (see lifecycle) so a new AL2023 release never replaces the runner by itself.
data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter_name
}

################################################################################
# Network: no inbound rules, HTTPS egress only
################################################################################

resource "aws_security_group" "runner" {
  name        = local.name
  description = "Stage 2 runner: no inbound rules, egress TCP 443 only"
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = local.name })
}

# The runner reaches SSM, S3, GitHub, HashiCorp, dl.k8s.io and public.ecr.aws, which have no fixed
# addresses. The private subnet NACLs already restrict internet egress to TCP 443.
#trivy:ignore:AVD-AWS-0104
resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.runner.id
  description       = "HTTPS to AWS APIs, package and chart sources, and the private EKS endpoint"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"

  tags = var.tags
}

# The EKS docs state that the cluster security group rules control access to the private endpoint
resource "aws_vpc_security_group_ingress_rule" "cluster_api" {
  security_group_id            = var.cluster_security_group_id
  description                  = "Stage 2 runner to the private EKS API endpoint"
  referenced_security_group_id = aws_security_group.runner.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443

  tags = var.tags
}

################################################################################
# IAM: Session Manager, session logs, Terraform state, add-on check
################################################################################

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "runner" {
  name               = local.name
  description        = "Stage 2 runner: Session Manager, Terraform state of stacks/cluster and EKS add-on lookup"
  assume_role_policy = data.aws_iam_policy_document.assume.json

  tags = var.tags
}

resource "aws_iam_instance_profile" "runner" {
  name = local.name
  role = aws_iam_role.runner.name

  tags = var.tags
}

# Wildcard resources (all other statements are scoped):
# - ssm:UpdateInstanceInformation supports resource-level permissions (instance and managed-instance
#   resource types in the AWS service reference). "*" is kept because it matches the minimal Session
#   Manager policy in the AWS Systems Manager User Guide and an exact instance ARN would create a
#   dependency cycle (instance, instance profile, role, policy, instance). Scoping it with
#   instance/* is untested and is a follow-up after the first live run.
# - ssmmessages:* and logs:DescribeLogGroups have no resource types in the AWS service reference.
# The Trivy ignores below sit on the two attribute lines that are flagged, not on the whole
# document, so a wildcard added to any other statement is still reported.
data "aws_iam_policy_document" "runner" {
  statement {
    sid    = "SessionManager"
    effect = "Allow"
    actions = [
      "ssm:UpdateInstanceInformation",
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }

  statement {
    sid     = "SessionLogsDescribeGroups"
    effect  = "Allow"
    actions = ["logs:DescribeLogGroups"]
    # Justification: logs:DescribeLogGroups has no resource types (AWS service reference) and the
    # SSM agent calls it for session logging.
    #trivy:ignore:AVD-AWS-0057
    resources = ["*"]
  }

  statement {
    sid    = "SessionLogsWrite"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents",
    ]
    # Justification: false positive. The resource is the log group ARN reference below; the scanner cannot
    # resolve it at scan time and reports it as a wildcarded placeholder. The rendered policy is
    # scoped to this log group.
    #trivy:ignore:AVD-AWS-0057
    resources = ["${aws_cloudwatch_log_group.sessions.arn}:*"]
  }

  statement {
    sid       = "StateBucketList"
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.state_prefix}/*"]
    }
  }

  statement {
    sid       = "StateStage1Read"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}/${var.infra_state_key}"]
  }

  statement {
    sid       = "StateStage2ReadWrite"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}/${var.cluster_state_key}"]
  }

  statement {
    sid       = "StateStage2Lock"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["arn:aws:s3:::${var.state_bucket_name}/${var.cluster_state_key}.tflock"]
  }

  # Used by data "aws_eks_addon" in stacks/cluster (existence check of the Pod Identity agent)
  statement {
    sid       = "EksAddonLookup"
    effect    = "Allow"
    actions   = ["eks:DescribeAddon"]
    resources = ["arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:addon/${var.cluster_name}/*/*"]
  }

  # Needed by aws eks update-kubeconfig
  statement {
    sid       = "EksDescribeCluster"
    effect    = "Allow"
    actions   = ["eks:DescribeCluster"]
    resources = ["arn:aws:eks:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:cluster/${var.cluster_name}"]
  }
}

resource "aws_iam_role_policy" "runner" {
  name   = "stage2-runner"
  role   = aws_iam_role.runner.id
  policy = data.aws_iam_policy_document.runner.json
}

################################################################################
# Session Manager logging
################################################################################

# Justification: CloudWatch Logs encrypts log data at rest with a service-managed key; a customer
# managed key would add a KMS key to maintain for a single-operator log group.
#trivy:ignore:AVD-AWS-0017
resource "aws_cloudwatch_log_group" "sessions" {
  name              = "/ssm/session-manager/${var.cluster_name}"
  retention_in_days = var.session_log_retention_in_days

  tags = var.tags
}

# Session document used only by this runner. Sessions get its logging and idle timeout only when
# started with --document-name (see the ssm_session_command output). The account default document
# SSM-SessionManagerRunShell is not managed here.
resource "aws_ssm_document" "session_preferences" {
  name            = local.session_document_name
  document_type   = "Session"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "1.0"
    description   = "Session Manager preferences of the stage 2 runner: stream session logs to CloudWatch Logs"
    sessionType   = "Standard_Stream"
    inputs = {
      s3BucketName                = ""
      s3KeyPrefix                 = ""
      s3EncryptionEnabled         = false
      cloudWatchLogGroupName      = aws_cloudwatch_log_group.sessions.name
      cloudWatchEncryptionEnabled = false
      cloudWatchStreamingEnabled  = true
      kmsKeyId                    = ""
      runAsEnabled                = false
      runAsDefaultUser            = ""
      idleSessionTimeout          = tostring(var.session_idle_timeout_minutes)
      maxSessionDuration          = ""
      shellProfile = {
        windows = ""
        linux   = ""
      }
    }
  })

  tags = var.tags
}

################################################################################
# Example operator policy (rendered only, never attached by this module)
################################################################################

# EXAMPLE ONLY: the operator attaches an adapted copy to their own identity outside this repository.
# It allows sessions on the runner with the runner session document and nothing else, so a
# start-session call without --document-name (default document) or with another document has no
# allow. To select the instance by tag instead of by ID, use the ssm:resourceTag/Component condition
# on the instance ARN pattern (AWS Session Manager policy examples). Untested on a live instance.
data "aws_iam_policy_document" "operator_example" {
  statement {
    sid       = "StartSessionOnRunnerInstance"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = [aws_instance.runner.arn]
  }

  statement {
    sid       = "StartSessionWithRunnerDocument"
    effect    = "Allow"
    actions   = ["ssm:StartSession"]
    resources = [aws_ssm_document.session_preferences.arn]
  }

  statement {
    sid       = "OpenOwnDataChannel"
    effect    = "Allow"
    actions   = ["ssmmessages:OpenDataChannel"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:session/$${aws:userid}-*"]
  }

  statement {
    sid       = "ResumeAndTerminateOwnSessions"
    effect    = "Allow"
    actions   = ["ssm:ResumeSession", "ssm:TerminateSession"]
    resources = ["arn:aws:ssm:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:session/$${aws:userid}-*"]
  }

  # Only needed to start the session from the Session Manager console
  statement {
    sid       = "ConsoleGetRunnerDocument"
    effect    = "Allow"
    actions   = ["ssm:GetDocument"]
    resources = [aws_ssm_document.session_preferences.arn]
  }

  # ssm:ListDocuments has no resource types in the AWS service reference
  statement {
    sid       = "ConsoleListDocuments"
    effect    = "Allow"
    actions   = ["ssm:ListDocuments"]
    resources = ["*"]
  }
}

################################################################################
# Runner instance
################################################################################

resource "aws_instance" "runner" {
  ami                         = data.aws_ssm_parameter.ami.insecure_value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = [aws_security_group.runner.id]
  iam_instance_profile        = aws_iam_instance_profile.runner.name
  associate_public_ip_address = false

  # The file is stored with the repository line endings; the script must reach the instance with LF
  user_data = replace(templatefile("${path.module}/user_data.sh.tftpl", {
    swap_size_gb      = var.swap_size_gb
    terraform_version = var.terraform_version
    hashicorp_pgp_key = file("${path.module}/hashicorp-pgp-key.asc")
    kubectl_version   = var.kubectl_version
    kubectl_sha256    = var.kubectl_sha256
  }), "\r\n", "\n")
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_size_gb
    encrypted             = true
    delete_on_termination = true
  }

  tags        = merge(var.tags, { Name = local.name })
  volume_tags = merge(var.tags, { Name = local.name })

  lifecycle {
    ignore_changes = [ami]
  }

  # The instance profile policy must exist before the SSM agent first registers
  depends_on = [aws_iam_role_policy.runner]
}

################################################################################
# EKS access: cluster admin for the runner role (API_AND_CONFIG_MAP access entries)
################################################################################

resource "aws_eks_access_entry" "runner" {
  cluster_name  = var.cluster_name
  principal_arn = aws_iam_role.runner.arn
  type          = "STANDARD"

  tags = var.tags
}

# Helm releases create ClusterRoles, ClusterRoleBindings and CRDs, which AmazonEKSAdminPolicy does not allow
resource "aws_eks_access_policy_association" "runner" {
  cluster_name  = var.cluster_name
  principal_arn = aws_eks_access_entry.runner.principal_arn
  policy_arn    = local.cluster_admin_policy_arn

  access_scope {
    type = "cluster"
  }
}
