#!/bin/bash
set -euo pipefail
NAMESPACE=${NAMESPACE:-neops}
if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${QUAY_USER:=}" "${QUAY_TOKEN:=}"
if [ -f cms_api_key.env ]; then set -a; . ./cms_api_key.env; set +a; fi

if [ ! -f jwt/private.pem ] || [ ! -f jwt/public.pem ]; then
  mkdir -p jwt
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt/private.pem
  openssl rsa -in jwt/private.pem -pubout -out jwt/public.pem
fi

# Self-heal a fresh checkout: fetch the pinned subcharts from Quay/Docker Hub.
# `make lock-dependencies` stays the explicit path after a Chart.yaml version bump.
# Fetch when any declared dependency is unsatisfied, not merely when charts/ is
# empty: adding a dependency leaves the directory populated but incomplete. Fail fast
# when the listing itself fails, so a broken chart cannot look like "nothing to fetch".
if ! deps=$(helm dependency list charts/neops); then
  echo "error: 'helm dependency list charts/neops' failed, so whether the subcharts are present is unknown (its error is above)" >&2
  exit 1
fi
if printf '%s\n' "$deps" | awk 'NR>1 && NF && $NF != "ok" { missing = 1 } END { exit !missing }'; then
  test -n "$QUAY_TOKEN" || { echo "a subchart declared in Chart.yaml is missing from charts/ and .env has no QUAY_TOKEN: run 'make init' after filling .env, or 'make charts-cutting-edge' at the workspace root" >&2; exit 1; }
  echo "$QUAY_TOKEN" | helm registry login quay.io --username "$QUAY_USER" --password-stdin
  helm dependency build charts/neops
fi

token_args=()
if [ -n "${NEOPS_CMS_TOKEN:-}" ]; then
  token_args=(--set-string "neops-workflow-engine.secrets.NEOPS_CMS_TOKEN=$NEOPS_CMS_TOKEN"
              --set-string "neops-secure-gateway.secrets.STATIC_AUTH_TOKEN=$NEOPS_CMS_TOKEN")
fi

helm upgrade --install neops charts/neops --namespace "$NAMESPACE" --create-namespace \
  --timeout 15m \
  --values charts/neops/values-kind.yaml \
  --set-file neops-core.jwt.privateKey=jwt/private.pem --set-file neops-core.jwt.publicKey=jwt/public.pem \
  --set-string "registry.username=$QUAY_USER" --set-string "registry.password=$QUAY_TOKEN" \
  "${token_args[@]}"

# Cap revision history so stale ReplicaSets do not pile up (subcharts expose no value for it).
kubectl -n "$NAMESPACE" get deployment -l app.kubernetes.io/instance=neops -o name \
  | xargs -r -I{} kubectl -n "$NAMESPACE" patch {} --type=merge -p '{"spec":{"revisionHistoryLimit":2}}'

# Pick up freshly kind-loaded images under an unchanged tag.
kubectl -n "$NAMESPACE" rollout restart deployment -l app.kubernetes.io/instance=neops
kubectl -n "$NAMESPACE" get pods -o custom-columns='NAME:.metadata.name,IMAGE:.status.containerStatuses[*].image'
