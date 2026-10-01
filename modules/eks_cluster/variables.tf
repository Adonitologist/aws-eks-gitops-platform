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
  description = "Versión de Kubernetes para el plano de control de EKS"
  type        = string
  default     = "1.31"
}

variable "system_node_instance_types" {
  description = "Tipos de instancia EC2 para el System Node Group"
  type        = list(string)
  default     = ["t3.medium"]

  validation {
    condition     = length(var.system_node_instance_types) > 0
    error_message = "At least one instance type is required."
  }
}

variable "system_node_min_size" {
  description = "Minimum number of nodes in the System Node Group (Karpenter needs at least 2 nodes: hard per-host anti-affinity)"
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
  description = "Maximum number of nodes in the System Node Group (keep headroom for rolling updates)"
  type        = number
  default     = 3

  validation {
    condition     = var.system_node_max_size >= 1
    error_message = "system_node_max_size must be >= 1."
  }
}
