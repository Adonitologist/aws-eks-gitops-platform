variable "cluster_name" {
  description = "EKS cluster name, used for resource naming and subnet discovery tags"
  type        = string
}

variable "vpc_cidr" {
  description = "Primary CIDR block of the VPC"
  type        = string

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid IPv4 CIDR block."
  }
}

variable "azs" {
  description = "Availability zones used for the private and public subnets (one subnet per zone)"
  type        = list(string)

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least 2 availability zones are required."
  }
}

variable "flow_log_retention_in_days" {
  description = "Retention in days of the VPC flow logs CloudWatch log group"
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_in_days)
    error_message = "flow_log_retention_in_days must be a value supported by CloudWatch Logs."
  }
}
