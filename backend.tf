terraform {
  backend "s3" {
    bucket  = "eks-gitops-tfstate-154932391641"
    key     = "eks-gitops-platform/terraform.tfstate"
    region  = "us-east-1"
    encrypt = true
    # dynamodb_table = "tu-tabla-dynamo" # Úsalo solo si requieres bloqueo de estado en TF 1.5.0
  }
}