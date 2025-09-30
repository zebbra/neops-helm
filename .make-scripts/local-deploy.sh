#!/bin/bash

set -e
set -a             # Automatically export all variables
source .env        # Load the file
set +a             # Stop automatic exporting
kind create cluster --config kind/kind-config.yaml
kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml --wait
# Install Rancher local-path-provisioner
kubectl apply -f https://raw.githubusercontent.com/rancher/local-path-provisioner/master/deploy/local-path-storage.yaml --wait
# Wait until it’s up
kubectl -n local-path-storage rollout status deploy/local-path-provisioner
# (optional) make it the default StorageClass
kubectl annotate storageclass local-path storageclass.kubernetes.io/is-default-class="true" --overwrite
# verify
kubectl get storageclass
sleep 10
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=90s
kubectl get pods -n ingress-nginx
helm registry login ghcr.io --username $GITHUB_USER --password $GITHUB_TOKEN
helm registry login quay.io --username $QUAY_USER --password $QUAY_TOKEN
(source .env  && cd charts/neops && helm repo add bitnami https://charts.bitnami.com/bitnami)
(source .env  && cd charts/neops && helm repo update)
(source .env  && cd charts/neops && helm dependency build)
echo "Start installing neops chart"
helm install neops charts/neops --values charts/neops/values.yaml --set logins[0].username="${QUAY_USER}" --set logins[0].password="${QUAY_TOKEN}"
kubectl get pods