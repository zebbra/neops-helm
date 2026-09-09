#!/bin/bash
set -euo pipefail
NAMESPACE=${NAMESPACE:-neops}
helm uninstall neops --namespace "$NAMESPACE" --ignore-not-found
kubectl delete namespace "$NAMESPACE" --ignore-not-found --wait=true
rm -f cms_api_key.env
rm -rf jwt
