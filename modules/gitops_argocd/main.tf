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
  version    = "7.3.11"

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
        # Deshabilitar TLS interno para permitir SSL offloading en el AWS ALB
        extraArgs = ["--insecure"]
        
        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"       = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"  = "ip"
            "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "alb.ingress.kubernetes.io/listen-ports" = "[{\"HTTP\": 80}]"
          }
          # Enrutamiento base para la interfaz de usuario
          paths = ["/"]
        }
      }
    })
  ]
}