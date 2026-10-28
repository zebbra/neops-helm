#!/bin/bash
set -euo pipefail
NAMESPACE=${NAMESPACE:-neops}
if [ -f .env ]; then set -a; . ./.env; set +a; fi
: "${QUAY_USER:=}" "${QUAY_TOKEN:=}"
: "${KIND_DOMAIN:=neops.local}" "${KIND_SCHEME:=http}"
if [ -f cms_api_key.env ]; then set -a; . ./cms_api_key.env; set +a; fi

if [[ "$KIND_SCHEME" != "http" && "$KIND_SCHEME" != "https" ]]; then
  echo "error: invalid KIND_SCHEME '$KIND_SCHEME': must be 'http' or 'https'" >&2
  exit 1
fi
if ! [[ "$KIND_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ ]]; then
  echo "error: invalid KIND_DOMAIN '$KIND_DOMAIN': must match ^[a-zA-Z0-9.-]+$" >&2
  exit 1
fi

render_domain_values() {
  cat <<EOF
neops-core:
  env:
    DJANGO_ALLOWED_HOSTS: cms.${KIND_DOMAIN},cms.neops.local,neops-neops-core
  ingress:
    hosts:
      - host: cms.${KIND_DOMAIN}
        paths:
          - path: /
            pathType: Prefix
      - host: cms.neops.local
        paths:
          - path: /
            pathType: Prefix

neops-workflow-engine:
  env:
    NEOPS_CORS_ORIGINS: ${KIND_SCHEME}://${KIND_DOMAIN},${KIND_SCHEME}://workflows.${KIND_DOMAIN},http://neops.local,http://workflows.neops.local
  ingress:
    hosts:
      - host: engine.${KIND_DOMAIN}
        paths:
          - path: /
            pathType: Prefix
      - host: engine.neops.local
        paths:
          - path: /
            pathType: Prefix

neops-monitor-app:
  env:
    ENGINE_BASE_URL: ${KIND_SCHEME}://engine.${KIND_DOMAIN}
    WEBCLIENT_ORIGIN: ${KIND_SCHEME}://${KIND_DOMAIN}
  ingress:
    hosts:
      - host: workflows.${KIND_DOMAIN}
        paths:
          - path: /
            pathType: Prefix
      - host: workflows.neops.local
        paths:
          - path: /
            pathType: Prefix

neops-web-client:
  env:
    FRONTEND_GRAPHQL_ENDPOINT: ${KIND_SCHEME}://cms.${KIND_DOMAIN}/graphql
    FRONTEND_FILEAPI_ENDPOINT: ${KIND_SCHEME}://storage.${KIND_DOMAIN}/
    FRONTEND_WORKFLOW_MANAGER_URL: ${KIND_SCHEME}://workflows.${KIND_DOMAIN}
  ingress:
    hosts:
      - host: ${KIND_DOMAIN}
        paths:
          - path: /
            pathType: Prefix
      - host: neops.local
        paths:
          - path: /
            pathType: Prefix

neops-secure-gateway:
  ingress:
    hosts:
      - host: gateway.${KIND_DOMAIN}
        paths:
          - path: /
            pathType: Prefix
      - host: gateway.neops.local
        paths:
          - path: /
            pathType: Prefix

neops-storage:
  ingress:
    hosts:
      - host: storage.${KIND_DOMAIN}
        paths:
          - path: /
            pathType: Prefix
      - host: storage.neops.local
        paths:
          - path: /
            pathType: Prefix
EOF
}

get_container_image() {
  local target=$1
  local container=$2
  local get_args=(-l "$target")
  if [[ "$target" == pod/* || "$target" == pod\ * ]]; then
    get_args=("$target")
  fi
  local img
  img=$(kubectl -n "$NAMESPACE" get pod "${get_args[@]}" -o json 2>/dev/null \
    | jq -r --arg c "$container" '
        (if .items then [ .items[] | select(.metadata.deletionTimestamp == null) ][0] // .items[0] else . end) as $pod
        | ($pod.status.containerStatuses[]? | select(.name == $c) | .imageID)
          // ($pod.spec.containers[]? | select(.name == $c) | .image)
          // ""
      ' 2>/dev/null || true)
  printf '%s' "$img"
}

get_schema_hash() {
  local pod=$1
  kubectl -n "$NAMESPACE" exec "$pod" -- ./manage.py elastic_index --schema-hash 2>/dev/null \
    | awk 'NF{h=$NF} END{print h}' | grep -E '^[0-9a-f]{64}$' || true
}

is_search_index_stale() {
  local before_es=$1 after_es=$2 before_core=$3 after_core=$4 before_schema=$5 after_schema=$6
  if [ "$before_es" != "$after_es" ]; then
    return 0
  fi
  if [ -z "$after_schema" ]; then
    return 1
  fi
  if [ -z "$before_schema" ]; then
    if [ "$before_core" != "$after_core" ]; then
      return 0
    fi
    return 1
  fi
  if [ "$before_schema" != "$after_schema" ]; then
    return 0
  fi
  return 1
}

rebuild_search_index() {
  local pod=$1
  echo "the search index no longer matches neops-core or Elasticsearch: rebuilding it"
  local flags=(--rebuild --force)
  if kubectl -n "$NAMESPACE" exec "$pod" -- ./manage.py elastic_index --help 2>&1 | grep -- '--sync-lookups' >/dev/null; then
    flags+=(--sync-lookups)
  fi
  kubectl -n "$NAMESPACE" exec "$pod" -- ./manage.py elastic_index "${flags[@]}"
}

# Core signs its tokens with this keypair and the engine verifies them with the
# public half, refusing to boot without it.
if [ ! -f jwt/private.pem ] || [ ! -f jwt/public.pem ]; then
  mkdir -p jwt
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out jwt/private.pem
  openssl rsa -in jwt/private.pem -pubout -out jwt/public.pem
fi

# Self-heal dependencies: refresh Chart.lock and charts/ whenever any declared
# dependency is missing or at the wrong version (e.g. after a Chart.yaml pin bump
# or on a fresh checkout). Fail fast when the listing itself fails, so a broken
# chart cannot look like "nothing to fetch".
if ! deps=$(helm dependency list charts/neops); then
  echo "error: 'helm dependency list charts/neops' failed, so whether the subcharts are present is unknown (its error is above)" >&2
  exit 1
fi
if printf '%s\n' "$deps" | awk 'NR>1 && NF && $NF != "ok" { missing = 1 } END { exit !missing }'; then
  test -n "$QUAY_TOKEN" || { echo "a subchart declared in Chart.yaml is missing from charts/ and .env has no QUAY_TOKEN: run 'make init' after filling .env, or 'make charts-cutting-edge' at the workspace root" >&2; exit 1; }
  echo "$QUAY_TOKEN" | helm registry login quay.io --username "$QUAY_USER" --password-stdin
  helm dependency update charts/neops
fi

token_args=()
if [ -n "${NEOPS_CMS_TOKEN:-}" ]; then
  token_args=(--set-string "neops-workflow-engine.secrets.NEOPS_CMS_TOKEN=$NEOPS_CMS_TOKEN"
              --set-string "neops-secure-gateway.secrets.STATIC_AUTH_TOKEN=$NEOPS_CMS_TOKEN")
fi

is_upgrade=false
before_core_image=""
before_es_image=""
before_schema=""
if helm status neops -n "$NAMESPACE" >/dev/null 2>&1; then
  is_upgrade=true
  before_core_pod=$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=neops-core,app.kubernetes.io/component=app -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | "pod/" + .metadata.name' 2>/dev/null | awk 'NR==1' || true)
  if [ -n "$before_core_pod" ]; then
    before_schema=$(get_schema_hash "$before_core_pod")
  fi
  before_core_image=$(get_container_image "app.kubernetes.io/name=neops-core,app.kubernetes.io/component=app" "neops-core")
  before_es_image=$(get_container_image "app.kubernetes.io/name=elasticsearch,app.kubernetes.io/component=master" "elasticsearch")
fi

domain_args=()
if [ "$KIND_DOMAIN" != "neops.local" ] || [ "$KIND_SCHEME" != "http" ]; then
  domain_args=(--values <(render_domain_values))
fi

helm upgrade --install neops charts/neops --namespace "$NAMESPACE" --create-namespace \
  --timeout 15m \
  --values charts/neops/values-kind.yaml \
  "${domain_args[@]}" \
  --set-file neops-core.jwt.privateKey=jwt/private.pem --set-file neops-core.jwt.publicKey=jwt/public.pem \
  --set-file neops-workflow-engine.secrets.NEOPS_JWT_PUBLIC_KEY=jwt/public.pem \
  --set-string "registry.username=$QUAY_USER" --set-string "registry.password=$QUAY_TOKEN" \
  "${token_args[@]}"

# Cap revision history so stale ReplicaSets do not pile up (subcharts expose no value for it).
kubectl -n "$NAMESPACE" get deployment -l app.kubernetes.io/instance=neops -o name \
  | xargs -r -I{} kubectl -n "$NAMESPACE" patch {} --type=merge -p '{"spec":{"revisionHistoryLimit":2}}'

# Pick up freshly kind-loaded images under an unchanged tag.
kubectl -n "$NAMESPACE" rollout restart deployment -l app.kubernetes.io/instance=neops

if [ "$is_upgrade" = true ]; then
  if kubectl -n "$NAMESPACE" get deployment/neops-neops-core >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" rollout status deployment/neops-neops-core --timeout=600s
  fi
  if kubectl -n "$NAMESPACE" get statefulset/neops-elasticsearch-master >/dev/null 2>&1; then
    kubectl -n "$NAMESPACE" rollout status statefulset/neops-elasticsearch-master --timeout=600s
  fi
  pod=$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=neops-core,app.kubernetes.io/component=app -o json 2>/dev/null \
    | jq -r '.items[] | select(.metadata.deletionTimestamp == null) | "pod/" + .metadata.name' 2>/dev/null | awk 'NR==1' || true)
  test -n "$pod" || { echo "error: no core app pod in namespace $NAMESPACE yet" >&2; exit 1; }
  kubectl -n "$NAMESPACE" wait --for=condition=ready "$pod" --timeout=600s

  after_schema=$(get_schema_hash "$pod")
  after_core_image=$(get_container_image "$pod" "neops-core")
  after_es_image=$(get_container_image "app.kubernetes.io/name=elasticsearch,app.kubernetes.io/component=master" "elasticsearch")

  if is_search_index_stale "$before_es_image" "$after_es_image" "$before_core_image" "$after_core_image" "$before_schema" "$after_schema"; then
    rebuild_search_index "$pod"
  fi
fi

kubectl -n "$NAMESPACE" get pods -o custom-columns='NAME:.metadata.name,IMAGE:.status.containerStatuses[*].image'
