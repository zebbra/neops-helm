#!/bin/bash

set -e
source .env        # Load the file
echo "Start upgrading neops chart"
helm upgrade neops charts/neops --values charts/neops/values.yaml --set logins[0].username="${QUAY_USER}" --set logins[0].password="${QUAY_TOKEN}"
kubectl -n default rollout restart deployment
kubectl get pods -o custom-columns='NAME:.metadata.name,IMAGE_TAG:.status.containerStatuses[*].image' 

