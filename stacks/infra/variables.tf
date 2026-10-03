variable "aws_region" {
  description = "Primary deployment region"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Execution environment"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "Primary CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Availability zones for the VPC subnets (one private and one public subnet per zone)"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]

  validation {
    condition     = length(var.azs) >= 2
    error_message = "At least 2 availability zones are required."
  }
}

# Must match the bucket in the backend blocks of stacks/infra and stacks/cluster.
variable "state_bucket_name" {
  description = "Name of the S3 bucket that holds the Terraform state of both stacks (must match the backend blocks)"
  type        = string
  default     = "eks-gitops-tfstate-154932391641"
}
