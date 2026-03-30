# neops-helm

Kubernetes deployment manifests for the neops platform. Contains three independent Helm charts that package the neops-core Django application, the Angular web client, and a legacy Storybook into production-ready Kubernetes deployments with infrastructure sub-charts, lifecycle hooks, and environment overlays.

Tech: Helm 3 (apiVersion v2), Kubernetes YAML templates, Helmfile

## Charts

| Chart | Version | Purpose |
|---|---|---|
| `neops` | 0.1.3 | Primary platform: Django app + Celery worker + sub-charts (ES, Kibana, Redis, etcd) |
| `neops-web-client` | 0.1.0 | Angular SPA frontend |
| `carbon-angular-storybook` | 0.1.5 | Legacy Carbon Angular component showcase |

## Development

```bash
# Lint a chart
helm lint charts/neops

# Template render (dry-run)
helm template my-release charts/neops -f charts/neops/values.yaml

# Template with environment overlay
helm template my-release charts/neops -f charts/neops/values.yaml -f charts/neops/environments/demo.yaml

# Update sub-chart dependencies
helm dependency update charts/neops

# Install/upgrade
helm upgrade --install neops charts/neops -f charts/neops/environments/demo.yaml
```

## Conventions

- Environment overlays live in `charts/<name>/environments/` (demo.yaml, preview.yaml)
- Sub-charts are vendored as `.tgz` archives in `charts/neops/charts/`
- Both app and worker Deployments share the same container image (`quay.io/zebbra/neops-core`)
- ConfigMap and Secret checksums on pod annotations trigger rolling restarts on config change
- Ingress template auto-detects Kubernetes version (supports 1.14+, 1.18+, 1.19+ API variants)

## Gotchas & Boundaries

- NEVER delete an existing Secret and recreate it on upgrade -- the `secrets.yaml` template uses Helm `lookup` to preserve existing secret values; overwriting them rotates credentials
- ALWAYS set `image.tag` explicitly when deploying -- the worker template has no `default .Chart.AppVersion` fallback unlike the app deployment
- Hook jobs (`db-migrate`, `es-rebuild`) have `before-hook-creation` delete policy -- they delete and recreate on each upgrade; disable with `hooks.enabled: false`
- Sub-chart dependency versions are locked from 2023 (`Chart.lock` generated 2023-09-18) -- run `helm dependency update` after changing versions in `Chart.yaml`
- OpenVPN sidecar requires `NET_ADMIN` capability and an independently managed ConfigMap named by `openvpn.configName`
- The `db-migrate` hook uses partial env injection (conditionally `existingSecret` or individual vars), unlike app/worker which use full `envFrom`

## Ecosystem Context

- **Deploys**: neops-core (Django + Celery) via `quay.io/zebbra/neops-core` and neops-web-client (Angular) via `quay.io/zebbra/neops-web-client`
- **Consumed by**: Operations teams deploying to demo.neops.io and preview.neops.io
- **No runtime dependency on**: neops-workflow-engine, neops-worker-sdk-py, neops-remote-lab (these are not deployed by these charts)

## Key Configuration

| Variable | Default | Purpose |
|---|---|---|
| `image.repository` | `quay.io/zebbra/neops-core` | Container image for app + worker |
| `image.tag` | `""` (appVersion: latest) | Image tag |
| `config.NEOPS_PLUGINS` | `""` | Space-separated plugin list |
| `config.DEBUG` | `"False"` | Django debug mode |
| `secrets.DJANGO_SECRET_KEY` | `insecure-default-secret` | Django secret (override in production) |
| `secrets.DATABASE_URL` | `postgres://neops-postgres:5432/neops` | PostgreSQL connection |
| `secrets.REDIS_URL` | `redis://neops-redis:6379/0` | Redis broker/cache |
| `secrets.ELASTICSEARCH_HOSTS` | `http://neops-es-master:9200` | Elasticsearch endpoint |
| `existingSecret` | `""` | Use pre-created K8s Secret instead of chart-managed |
| `hooks.enabled` | `true` | Enable/disable db-migrate and es-rebuild hooks |
| `worker.replicaCount` | `1` | Celery worker replicas |
| `worker.concurrency` | `1` | Celery worker concurrency |
| `openvpn.enabled` | `false` | Enable OpenVPN sidecar for network device access |
| `elasticsearch.enabled` | `false` | Deploy Elasticsearch sub-chart |
| `redis.enabled` | `false` | Deploy Redis sub-chart |
