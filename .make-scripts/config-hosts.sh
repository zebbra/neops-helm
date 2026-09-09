#!/bin/bash
set -euo pipefail
NAMESPACE=${NAMESPACE:-neops}

# The deployed release is the source of the hostnames, so adding a service needs no
# edit here. Only `.local` names belong in /etc/hosts; the public ones resolve
# through real DNS.
if ! rules=$(kubectl -n "$NAMESPACE" get ingress -o jsonpath='{range .items[*].spec.rules[*]}{.host}{"\n"}{end}'); then
  echo "error: kubectl could not read ingresses in namespace $NAMESPACE — check the current context and that the cluster is reachable (kubectl's own error is above)" >&2
  exit 1
fi

# kubectl succeeded, so an empty result means nothing is deployed rather than a broken
# connection. `|| true` keeps the guard reachable when grep matches nothing under `set -e`.
hosts=$(printf '%s\n' "$rules" | grep '\.local$' | sort -u) || true
test -n "$hosts" || { echo "error: no .local ingress hosts in namespace $NAMESPACE: deploy first with 'make local-deploy', then re-run this" >&2; exit 1; }

while read -r host; do
  entry="127.0.0.1 $host"
  grep -qF "$entry" /etc/hosts || echo "$entry" | sudo tee -a /etc/hosts >/dev/null
done <<< "$hosts"
