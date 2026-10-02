variable "environment" {
  description = "Entorno de despliegue"
  type        = string
}

variable "cluster_name" {
  description = "Nombre del cluster EKS"
  type        = string
}

variable "vpc_id" {
  description = "ID de la VPC donde se desplegara el cluster"
  type        = string
}

variable "subnet_ids" {
  description = "Subredes privadas para los nodos worker"
  type        = list(string)
}

variable "cluster_version" {
  description = "Versión de Kubernetes para el plano de control de EKS. Política: una versión menor por detrás de la última, con soporte estándar hasta 2027-03-27 (1.35)"
  type        = string
  default     = "1.35"
}

variable "system_node_instance_types" {
  description = "Tipos de instancia EC2 para el System Node Group"
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.system_node_instance_types) > 0
    error_message = "Se requiere al menos un tipo de instancia."
  }
}

variable "system_node_min_size" {
  description = "Número mínimo de nodos del System Node Group"
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_min_size >= 0 && var.system_node_min_size <= var.system_node_desired_size
    error_message = "system_node_min_size debe ser >= 0 y <= system_node_desired_size."
  }
}

variable "system_node_desired_size" {
  description = "Número deseado de nodos del System Node Group"
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_desired_size <= var.system_node_max_size
    error_message = "system_node_desired_size debe ser <= system_node_max_size."
  }
}

variable "system_node_max_size" {
  description = "Número máximo de nodos del System Node Group (dejar margen para actualizaciones graduales)"
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_max_size >= 1
    error_message = "system_node_max_size debe ser >= 1."
  }
}
