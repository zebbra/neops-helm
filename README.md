# neops-helm

Kubernetes deployment manifests for the [neops](https://neops.io) network automation platform. This repository contains three Helm charts that deploy the platform backend, web frontend, and a legacy component showcase.

## Prerequisites

Helm 3.x, kubectl, cluster access

## Development

```bash
# Validate charts
helm lint charts/neops
helm lint charts/neops-web-client

# Template render (dry-run)
helm template my-release charts/neops -f charts/neops/values.yaml

# Local testing with environment overlay
helm template my-release charts/neops -f charts/neops/values.yaml -f charts/neops/environments/demo.yaml
```

## Chart Structure

```
charts/
  neops/                         # Primary platform chart (v0.1.3)
    Chart.yaml                   # Helm v2 application chart
    Chart.lock                   # Pinned sub-chart versions
    charts/                      # Vendored sub-chart archives (.tgz)
    environments/                # Per-environment value overlays
      demo.yaml                  # demo.neops.io
      preview.yaml               # preview.neops.io
      matomo-values.yaml         # Matomo analytics
    templates/                   # Kubernetes resource templates
    values.yaml                  # Default configuration
  neops-web-client/              # Angular frontend chart (v0.1.0)
    environments/
    templates/
    values.yaml
  carbon-angular-storybook/      # Legacy Storybook chart (v0.1.5)
    helmfile.yaml
    templates/
    values.yaml
```

## Quick Start

```bash
# Add sub-chart repositories
helm repo add elastic https://helm.elastic.co
helm repo add bitnami https://charts.bitnami.com/bitnami

# Update sub-chart dependencies
helm dependency update charts/neops

# Validate templates
helm lint charts/neops
helm template my-release charts/neops -f charts/neops/values.yaml

# Deploy with environment overlay
helm upgrade --install neops charts/neops \
  -f charts/neops/values.yaml \
  -f charts/neops/environments/demo.yaml \
  --namespace neops --create-namespace
```

## Deployment Architecture

```
                    Helm Release
                         |
          +--------------+--------------+
          |              |              |
     neops chart    web-client     storybook
          |            chart          chart
    +-----+------+
    |     |      |
   App  Worker  Hooks
    |     |      |
    |     |    db-migrate (pre-install/pre-upgrade)
    |     |    es-rebuild (post-upgrade)
    |     |
    |   Celery worker (same image, independent scaling)
    |
  Django/Gunicorn (port 80)
    |
  Optional: OpenVPN sidecar
    |
  Sub-charts: Elasticsearch, Kibana, Redis, etcd
```

### neops Chart Resources

| Resource | Kind | Purpose |
|---|---|---|
| App | Deployment | Django/Gunicorn web server (port 80) |
| Worker | Deployment | Celery background worker (independent replica count) |
| Service | ClusterIP | Routes traffic to app pods |
| Ingress | Ingress | External access (multi-version K8s support) |
| ConfigMap | ConfigMap | Application configuration from `config:` values |
| Secrets | Secret | Credentials from `secrets:` values (preserved on upgrade) |
| db-migrate | Job (Hook) | Runs `manage.py migrate` before install/upgrade |
| es-rebuild | Job (Hook) | Runs `manage.py elastic_index --rebuild --force` after upgrade |

### Sub-Charts

| Dependency | Version | Purpose | Enabled By |
|---|---|---|---|
| Elasticsearch | 8.5.1 | Search and indexing | `elasticsearch.enabled` |
| Kibana | 8.5.1 | Elasticsearch UI | `kibana.enabled` |
| Redis | 18.0.4 | Message broker / cache | `redis.enabled` |
| etcd | 9.5.0 | Distributed key-value store | `etcd.enabled` |

All sub-charts are disabled by default and enabled via environment overlays.

## Configuration

Configuration is split between `config:` (ConfigMap, non-sensitive) and `secrets:` (Secret, sensitive):

```yaml
config:
  NEOPS_PLUGINS: ""
  DJANGO_ALLOWED_HOSTS: "*"
  DEBUG: "False"

secrets:
  DJANGO_SECRET_KEY: insecure-default-secret   # Override in production
  DATABASE_URL: postgres://neops-postgres:5432/neops
  REDIS_URL: redis://neops-redis:6379/0
  ELASTICSEARCH_HOSTS: http://neops-es-master:9200
```

To use a pre-existing Kubernetes Secret instead of chart-managed secrets:

```yaml
existingSecret: "my-neops-secrets"
```

## Important Notes

- **Secret preservation**: Existing secrets are preserved on `helm upgrade` via Helm `lookup`. This prevents accidental credential rotation.
- **Worker image**: The Celery worker uses the same container image as the app. Set `image.tag` explicitly -- the worker template has no `appVersion` fallback.
- **Hook jobs**: Database migration and Elasticsearch rebuild hooks run automatically. Disable with `hooks.enabled: false`.
- **OpenVPN sidecar**: Enable with `openvpn.enabled: true`. Requires `NET_ADMIN` capability and a pre-existing ConfigMap (default name: `neops-openvpn`).

## See Also

See [AGENTS.md](AGENTS.md) for AI agent context, conventions, and gotchas.

## Contributing

Default branch: `main`. Branch from `main` for all changes. Run verification: `helm lint charts/neops && helm lint charts/neops-web-client`

## License

Proprietary (zebbra AG).
