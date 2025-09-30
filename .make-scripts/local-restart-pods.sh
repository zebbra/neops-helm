kubectl rollout restart deployment -l app.kubernetes.io/instance=neops
kubectl wait --for=condition=available --timeout=60s deployment -l app.kubernetes.io/instance=neops
kubectl get pods -l app.kubernetes.io/instance=neops