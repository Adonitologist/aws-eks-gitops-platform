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
  default     = ["t3.micro"]
}
