# tflint-ignore: terraform_unused_declarations
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