#!/bin/bash

set -e
source .env        # Load the file
helm upgrade neops charts/neops --values charts/neops/values-kind.yaml --set secrets[0].password="${GITHUB_TOKEN}"
kubectl -n default rollout restart deployment
kubectl get pods -o custom-columns='NAME:.metadata.name,IMAGE_TAG:.status.containerStatuses[*].image' 

