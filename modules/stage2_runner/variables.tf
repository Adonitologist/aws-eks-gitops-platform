variable "cluster_name" {
  description = "EKS cluster name, used for resource naming, the session document name and the EKS access entry"
  type        = string

  validation {
    condition     = can(regex("^[0-9A-Za-z][0-9A-Za-z_-]{0,99}$", var.cluster_name)) && !can(regex("^(?i)(aws|amazon|amzn)", var.cluster_name))
    error_message = "cluster_name must be a valid EKS cluster name (up to 100 characters of letters, digits, hyphens and underscores) that does not start with aws, amazon or amzn, which are reserved SSM document name prefixes."
  }
}

variable "vpc_id" {
  description = "ID of the VPC where the runner security group is created"
  type        = string
}

variable "subnet_id" {
  description = "ID of the private subnet where the runner instance is launched (no public IP is assigned)"
  type        = string
}

variable "cluster_security_group_id" {
  description = "ID of the EKS cluster security group that controls access to the private API endpoint"
  type        = string
}

variable "state_bucket_name" {
  description = "Name of the S3 bucket that holds the Terraform state of both stacks (must match the backend blocks)"
  type        = string

  validation {
    condition     = length(trimspace(var.state_bucket_name)) > 0
    error_message = "state_bucket_name must not be empty."
  }
}

variable "infra_state_key" {
  description = "S3 key of the stage 1 state (the runner only reads it through terraform_remote_state)"
  type        = string
  default     = "eks-gitops-platform/terraform.tfstate"

  validation {
    condition     = can(regex("^[^/].*/[^/]+$", var.infra_state_key))
    error_message = "infra_state_key must be an S3 key with at least one path segment, for example prefix/terraform.tfstate."
  }
}

variable "cluster_state_key" {
  description = "S3 key of the stage 2 state (the runner reads and writes it, plus its .tflock object)"
  type        = string
  default     = "eks-gitops-platform/cluster.tfstate"

  validation {
    condition     = can(regex("^[^/].*/[^/]+$", var.cluster_state_key))
    error_message = "cluster_state_key must be an S3 key with at least one path segment, for example prefix/cluster.tfstate."
  }
}

variable "instance_type" {
  description = "EC2 instance type of the runner (Terraform with the aws and helm providers needs more than 1 GiB of RAM)"
  type        = string
  default     = "t3.small"

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*\\.[a-z0-9]+$", var.instance_type))
    error_message = "instance_type must look like t3.small."
  }
}

variable "ami_ssm_parameter_name" {
  description = "Public SSM parameter that resolves to the AL2023 x86_64 AMI used by the runner"
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"

  validation {
    condition     = startswith(var.ami_ssm_parameter_name, "/aws/service/ami-amazon-linux-latest/al2023-")
    error_message = "ami_ssm_parameter_name must be an AL2023 parameter under /aws/service/ami-amazon-linux-latest/."
  }
}

variable "root_volume_size_gb" {
  description = "Size in GiB of the encrypted gp3 root volume (providers, charts, repository clone and swap file)"
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size_gb >= 20 && var.root_volume_size_gb <= 200
    error_message = "root_volume_size_gb must be between 20 and 200."
  }
}

variable "swap_size_gb" {
  description = "Size in GiB of the swap file created at first boot"
  type        = number
  default     = 2

  validation {
    condition     = var.swap_size_gb >= 1 && var.swap_size_gb <= 8
    error_message = "swap_size_gb must be between 1 and 8."
  }
}

variable "terraform_version" {
  description = "Terraform version installed on the runner (keep in line with the CI version)"
  type        = string
  default     = "1.15.6"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.terraform_version))
    error_message = "terraform_version must be a plain x.y.z version."
  }
}

variable "kubectl_version" {
  description = "kubectl version installed on the runner (within one minor version of the cluster version)"
  type        = string
  default     = "1.35.9"

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+$", var.kubectl_version))
    error_message = "kubectl_version must be a plain x.y.z version."
  }
}

variable "kubectl_sha256" {
  description = "SHA256 of the linux/amd64 kubectl binary, taken from the .sha256 file published next to it on dl.k8s.io"
  type        = string
  default     = "3cfeaf80be482b435b0aa214aff6e0b2c312ee23c0ff20810c75517b6004c6eb"

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.kubectl_sha256))
    error_message = "kubectl_sha256 must be 64 lowercase hex characters."
  }
}

variable "session_log_retention_in_days" {
  description = "Retention in days of the CloudWatch log group that receives the Session Manager session logs"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.session_log_retention_in_days)
    error_message = "session_log_retention_in_days must be a value supported by CloudWatch Logs."
  }
}

variable "session_idle_timeout_minutes" {
  description = "Idle timeout in minutes of the Session Manager sessions started with the runner session document (1 to 60)"
  type        = number
  default     = 30

  validation {
    condition     = var.session_idle_timeout_minutes >= 1 && var.session_idle_timeout_minutes <= 60
    error_message = "session_idle_timeout_minutes must be between 1 and 60."
  }
}

variable "tags" {
  description = "Tags applied to every taggable resource of the module"
  type        = map(string)
  default     = {}
}
