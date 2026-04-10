clusterName: ${cluster_name}
region: ${region}
vpcId: ${vpc_id}

replicaCount: 2

serviceAccount:
  create: true
  name: aws-load-balancer-controller
  annotations:
    eks.amazonaws.com/role-arn: ${role_arn}

resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 200m
    memory: 256Mi

enableServiceMutatorWebhook: false

defaultTags:
  managed-by: aws-load-balancer-controller
  cluster: ${cluster_name}
