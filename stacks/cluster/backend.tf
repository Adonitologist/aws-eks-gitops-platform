terraform {
  backend "s3" {
    bucket       = "eks-gitops-tfstate-154932391641"
    key          = "eks-gitops-platform/cluster.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
