variable "environment" {
  description = "Deployment environment name"
  type        = string
}

variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "ID of the VPC where the cluster is deployed"
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the worker nodes"
  type        = list(string)
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane. Policy: one minor version behind the latest, with standard support until 2027-03-27 (1.35)"
  type        = string
  default     = "1.35"
}

variable "system_node_instance_types" {
  description = "EC2 instance types for the System Node Group"
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.system_node_instance_types) > 0
    error_message = "At least one instance type is required."
  }
}

variable "system_node_min_size" {
  description = "Minimum number of nodes in the System Node Group"
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_min_size >= 0 && var.system_node_min_size <= var.system_node_desired_size
    error_message = "system_node_min_size must be >= 0 and <= system_node_desired_size."
  }
}

variable "system_node_desired_size" {
  description = "Desired number of nodes in the System Node Group"
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_desired_size <= var.system_node_max_size
    error_message = "system_node_desired_size must be <= system_node_max_size."
  }
}

variable "system_node_max_size" {
  description = "Maximum number of nodes in the System Node Group (leave headroom for rolling updates)"
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_max_size >= 1
    error_message = "system_node_max_size must be >= 1."
  }
}
