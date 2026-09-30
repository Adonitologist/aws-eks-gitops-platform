output "configure_kubectl" {
  description = "Command to configure local kubectl access to the EKS cluster"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks_cluster.cluster_name}"
}

output "argocd_admin_password_command" {
  description = "Command to read the initial Argo CD admin password. The secret is only valid until the admin password is changed and should be deleted afterwards."
  value       = "kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath=\"{.data.password}\" | base64 -d"
}

output "argocd_server_forward" {
  description = "Command to reach the Argo CD UI locally through a port-forward"
  value       = "kubectl port-forward svc/argocd-server -n argocd 8080:443"
}
