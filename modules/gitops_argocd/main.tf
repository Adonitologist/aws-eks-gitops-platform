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
  version    = "10.9.6"

  values = [
    yamlencode({
      server = {
        service = {
          type = "ClusterIP"
        }
        # Disable internal TLS to allow SSL offloading at the AWS ALB
        extraArgs = ["--insecure"]

        ingress = {
          enabled          = true
          ingressClassName = "alb"
          annotations = {
            "alb.ingress.kubernetes.io/scheme"           = "internet-facing"
            "alb.ingress.kubernetes.io/target-type"      = "ip"
            "alb.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "alb.ingress.kubernetes.io/listen-ports"     = "[{\"HTTP\": 80}]"
          }
          # Base routing for the user interface
          paths = ["/"]
        }
      }
    })
  ]
}
