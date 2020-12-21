#!/usr/bin/env bash

set -e
if aws sts get-caller-identity; then
  echo "Authenticated for AWS account"
else
  echo "Failed to authenticate - try running `aws sts get-caller-identity`"
fi

export AWS_REGION=us-east-1
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity | jq -r .Account)

cd iac/
# terraform steps
terraform init
terraform apply -auto-approve

#
aws eks --region $(terraform output region) update-kubeconfig --name $(terraform output cluster_id)

# namespaces are needed for helm charts which should be applied before k8s manifests
kubectl apply -f manifests/namespaces.yaml

export CLUSTER_NAME=$(terraform output -json | jq -r .cluster_id.value)

# Set up necessary values files in needed
cat << EOF > charts/cluster-autoscaler-chart-values.yml
awsRegion: $AWS_REGION

rbac:
  create: true
  serviceAccount:
    # This value should match local.k8s_service_account_name in locals.tf
    name: cluster-autoscaler-aws-cluster-autoscaler-chart
    annotations:
      # This value should match the ARN of the role created by module.iam_assumable_role_admin in irsa.tf
      eks.amazonaws.com/role-arn: "arn:aws:iam::${AWS_ACCOUNT_ID}:role/cluster-autoscaler"

autoDiscovery:
  clusterName: ${CLUSTER_NAME}
  enabled: true
EOF

cat << EOF > charts/grafana-values.yml
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
    - name: Prometheus
      type: prometheus
      url: http://prometheus-server.prometheus.svc.cluster.local
      access: proxy
      isDefault: true
EOF

# add autoscaler chart repo
helm repo add autoscaler https://kubernetes.github.io/autoscaler
# add prometheus chart repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
# add grafana chart repo
helm repo add grafana https://grafana.github.io/helm-charts
# update chart repos
helm repo update

# install autoscaler
helm upgrade -i cluster-autoscaler --namespace kube-system autoscaler/cluster-autoscaler-chart --values=charts/cluster-autoscaler-values.yaml

# install prometheus server
helm upgrade -i prometheus prometheus-community/prometheus \
    --namespace prometheus \
    --set alertmanager.persistentVolume.storageClass="gp2",server.persistentVolume.storageClass="gp2"

# install grafana
helm upgrade -i grafana grafana/grafana \
    --namespace grafana \
    --set persistence.storageClassName="gp2" \
    --set persistence.enabled=true \
    --values charts/grafana-values.yaml


# helm upgrade -i aws-load-balancer-controller eks/aws-load-balancer-controller \
#   --set clusterName=$CLUSTER_NAME \
#   --set serviceAccount.create=false \
#   --set serviceAccount.name=aws-load-balancer-controller \
#   -n kube-system

kubectl apply -Rf manifests