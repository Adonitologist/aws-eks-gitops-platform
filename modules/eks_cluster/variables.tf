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