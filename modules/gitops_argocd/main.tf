resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  namespace  = kubernetes_namespace.argocd.metadata[0].name
  version    = "7.3.11" # Version estable recomendada

  # El servidor interno se mantiene aislado. La exposicion se gestionara via Ingress.
  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  # Deshabilitar TLS interno para permitir SSL offloading en el AWS ALB
  set {
    name  = "server.extraArgs[0]"
    value = "--insecure"
  }
}