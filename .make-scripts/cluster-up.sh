#!/bin/bash
set -euo pipefail
KIND_CLUSTER=${KIND_CLUSTER:-kind}
NAMESPACE=${NAMESPACE:-neops}

if ! kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER"; then
  kind create cluster --name "$KIND_CLUSTER" --config kind/kind-config.yaml
fi
kubectl config use-context "kind-$KIND_CLUSTER"

if ! kubectl get namespace ingress-nginx >/dev/null 2>&1; then
  kubectl apply -f https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml
fi
kubectl -n ingress-nginx wait --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
