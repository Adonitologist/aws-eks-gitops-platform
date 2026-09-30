variable "aws_region" {
  description = "Región principal de despliegue"
  type        = string
  default     = "us-east-1"
}

variable "environment" {
  description = "Entorno de ejecución"
  type        = string
  default     = "production"
}

variable "vpc_cidr" {
  description = "Bloque CIDR principal para la VPC"
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