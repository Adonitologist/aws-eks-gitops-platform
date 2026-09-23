terraform {
  backend "s3" {
    bucket         = "[INSERT_YOUR_TERRAFORM_STATE_BUCKET]"
    key            = "eks-gitops-platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "[INSERT_YOUR_DYNAMODB_LOCK_TABLE]"
    encrypt        = true
  }
}