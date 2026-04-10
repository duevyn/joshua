# =============================================================================
# Provider configuration — Helm and Kubernetes authenticate via EKS exec auth
# so that `terraform apply` works from any machine with valid AWS credentials
# without storing a static kubeconfig.
# =============================================================================

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args = [
        "eks", "get-token",
        "--cluster-name", module.eks.cluster_name,
        "--region", "us-west-2",
      ]
    }
  }
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", "us-west-2",
    ]
  }
}

# =============================================================================
# Namespace
# =============================================================================

resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "app.kubernetes.io/managed-by" = "terraform"
    }
  }
}

# =============================================================================
# Storage classes (replaces k8s/storage.yml manual step)
#
# gp3 is cheaper and faster than the gp2 StorageClass EKS ships with.
# kubernetes_storage_class_v1 creates the gp3 class; kubernetes_annotations
# patches the pre-existing gp2 class to remove its default annotation.
# All PVC-backed Helm releases depend on gp3 existing before they run.
# =============================================================================

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Retain"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true

  parameters = {
    type      = "gp3"
    encrypted = "true"
  }

  depends_on = [module.eks]
}

resource "kubernetes_annotations" "gp2_not_default" {
  api_version = "storage.k8s.io/v1"
  kind        = "StorageClass"

  metadata {
    name = "gp2"
  }

  annotations = {
    "storageclass.kubernetes.io/is-default-class" = "false"
  }

  depends_on = [module.eks]
}

# =============================================================================
# Grafana admin password — generated once, stored as a Kubernetes secret so
# the Helm chart can reference it without the value appearing in Terraform state
# as plaintext.
# =============================================================================

resource "random_password" "grafana_admin" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "grafana_admin" {
  metadata {
    name      = "grafana-admin-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin.result
  }
}

# =============================================================================
# AWS Load Balancer Controller
# Deploys into kube-system (same namespace the IRSA SA lives in).
# =============================================================================

resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.13.0"
  namespace  = "kube-system"

  values = [
    templatefile("${path.module}/helm-values/aws-load-balancer-controller.yml.tpl", {
      cluster_name = module.eks.cluster_name
      region       = "us-west-2"
      vpc_id       = module.vpc.vpc_id
      role_arn     = module.aws_load_balancer_controller_irsa.iam_role_arn
    })
  ]

  depends_on = [module.eks]
}

# =============================================================================
# Loki — log aggregation (SingleBinary mode; suitable for single-cluster use)
# =============================================================================

resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = "6.30.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name
  depends_on = [
    kubernetes_storage_class_v1.gp3,
    helm_release.kube_prometheus_stack,
  ]

  values = [file("${path.module}/helm-values/loki.yml")]
}

# =============================================================================
# Tempo — distributed tracing backend
# =============================================================================

resource "helm_release" "tempo" {
  name       = "tempo"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "tempo"
  version    = "1.21.1"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  depends_on = [
    kubernetes_storage_class_v1.gp3,
    helm_release.kube_prometheus_stack,
  ]

  values = [file("${path.module}/helm-values/tempo.yml")]
}

# =============================================================================
# kube-prometheus-stack — Prometheus + Grafana + Alertmanager + node-exporter
# =============================================================================

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = "70.4.2"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  # CRDs are large; allow extra time on first install
  timeout = 600

  values = [file("${path.module}/helm-values/kube-prometheus-stack.yml")]

  depends_on = [
    kubernetes_storage_class_v1.gp3,
    kubernetes_secret.grafana_admin,
    helm_release.aws_load_balancer_controller,
  ]
}

# =============================================================================
# OpenTelemetry Collector (contrib) — central telemetry collection layer
#
# Pipeline:
#   OTLP receivers (gRPC :4317, HTTP :4318)
#     → metrics  → Prometheus remote_write
#     → traces   → Tempo OTLP gRPC
#     → logs     → Loki push API
# =============================================================================

resource "helm_release" "otel_collector" {
  name       = "otel-collector"
  repository = "https://open-telemetry.github.io/opentelemetry-helm-charts"
  chart      = "opentelemetry-collector"
  version    = "0.125.0"
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [file("${path.module}/helm-values/otel-collector.yml")]

  depends_on = [
    helm_release.kube_prometheus_stack,
    helm_release.loki,
    helm_release.tempo,
  ]
}

# =============================================================================
# Outputs
# =============================================================================

output "grafana_port_forward" {
  description = "Port-forward command to access Grafana locally at http://localhost:3000"
  value       = "kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring"
}

output "server_port_forward" {
  description = "Port-forward command to access joshua-server locally at http://localhost:8080"
  value       = "kubectl port-forward svc/joshua-server 8080:80"
}

output "grafana_admin_password" {
  description = "Grafana admin password"
  value       = random_password.grafana_admin.result
  sensitive   = true
}
