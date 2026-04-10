# AWS Load Balancer Controller — production values.
#
# Rendered by Terraform via templatefile() with these variables:
#   cluster_name  — EKS cluster name (controller uses this to discover AWS resources)
#   region        — AWS region hosting the cluster
#   vpc_id        — VPC the controller provisions load balancers in
#   role_arn      — IRSA IAM role the service account assumes
#
# Chart reference:
#   https://github.com/aws/eks-charts/blob/master/stable/aws-load-balancer-controller/values.yaml

# ---- Required controller settings ----
clusterName: ${cluster_name}
region: ${region}
vpcId: ${vpc_id}

# ---- High availability ----
# Two replicas so a single node failure can't take out ingress reconciliation.
# The controller uses leader election, so only one replica reconciles at a
# time; the second is a warm standby that takes over if the leader is evicted.
replicaCount: 2

# ---- Service account (IRSA) ----
serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: ${role_arn}

# ---- Resource sizing ----
# The controller's memory grows with the number of Ingress / Service /
# TargetGroupBinding objects it watches. These requests fit comfortably on
# an m7i-flex.large node; raise the limits if you run hundreds of ingresses.
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

# ---- Service mutator webhook ----
# AWS recommends disabling this unless you need the controller to silently
# annotate LoadBalancer-type Services. Leaving it on can surprise operators
# by rewriting Service specs they didn't opt in to.
enableServiceMutatorWebhook: false

# ---- Default tags ----
# Applied to every AWS resource the controller provisions (ALBs, target
# groups, listener rules, security groups). Essential for cost allocation
# and ownership queries in AWS Cost Explorer / Resource Groups.
defaultTags:
  managed-by: aws-load-balancer-controller
  cluster: ${cluster_name}
