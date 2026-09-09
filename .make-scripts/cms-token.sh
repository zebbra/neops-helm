#!/bin/bash
set -euo pipefail
NAMESPACE=${NAMESPACE:-neops}
CMS_USERNAME=${CMS_USERNAME:-neops}

kubectl -n "$NAMESPACE" wait --for=condition=complete job -l app.kubernetes.io/component=migrate --timeout=900s || true
pod=$(kubectl -n "$NAMESPACE" get pod -l app.kubernetes.io/name=neops-core,app.kubernetes.io/component=app -o name | head -n1)
test -n "$pod" || { echo "error: no core app pod in namespace $NAMESPACE yet" >&2; exit 1; }
kubectl -n "$NAMESPACE" wait --for=condition=ready "$pod" --timeout=600s

pk=$(kubectl -n "$NAMESPACE" exec "$pod" -- ./manage.py shell -c "from django.contrib.auth import get_user_model; print('PK=%s' % get_user_model().objects.get(username='$CMS_USERNAME').pk)" | sed -n 's/^PK=//p' | tr -d '\r') || true
test -n "$pk" || { echo "error: could not resolve the CMS user '$CMS_USERNAME'" >&2; exit 1; }
key=$(kubectl -n "$NAMESPACE" exec "$pod" -- ./manage.py generate_api_key "$pk" workflow | awk 'NF{l=$0}END{print l}' | tr -d '\r') || true
test -n "$key" || { echo "error: generate_api_key returned an empty key" >&2; exit 1; }
echo "NEOPS_CMS_TOKEN=$key" > cms_api_key.env
echo "wrote cms_api_key.env (user pk $pk); run 'make local-upgrade' to hand it to the engine and gateway"
