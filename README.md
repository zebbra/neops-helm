# neops-helm

Umbrella Helm chart for the NeOps platform plus a local KIND loop.

`charts/neops` composes the NeOps services as OCI subcharts from
`oci://quay.io/zebbra/charts` (each service repo owns and publishes its own chart under
`chart/<name>/` on every tag) together with Bitnami `postgresql`, `redis`,
`elasticsearch` and `minio`. `values.yaml` holds in-cluster wiring only; every credential
comes from an environment values file. `values-kind.yaml` is the KIND environment: all
credentials are `unsafe`, images are the locally built `cutting-edge` tags, and every
service defaults to `http://*.neops.local`. Setting `KIND_DOMAIN` and `KIND_SCHEME` in
`.env` (e.g. `KIND_DOMAIN=neops.example.com`, `KIND_SCHEME=https`) publishes the release
under both `*.${KIND_DOMAIN}` and `*.neops.local`.

Quote numeric values under the workflow engine's `env:`, e.g. `BLACKBOARD_PENDING_JOB_TIMEOUT: "3600000"`:
Helm renders an unquoted large integer as `3.6e+06`, which engine 0.44.1 and later refuse at boot.

## Local loop

```bash
cp .env.dist .env          # QUAY_USER / QUAY_TOKEN (private images + charts)
make local-deploy          # cluster-up → install → mint CMS token → install again
make config-hosts          # points the release's *.neops.local hosts at 127.0.0.1
```

Working tree instead of Quay: from the workspace root run `make deploy-cutting-edge`
(builds every image, `kind load`s it, packages the sibling charts locally, then runs
`make local-deploy` here). No registry is involved, so that flow needs no `.env` — the
credentials above are only for pulling the images and charts from Quay.

The default KIND values publish `neops.local` and the `cms`, `engine`, `workflows` and
`gateway` subdomains over HTTP without a `tls:` section. When `KIND_DOMAIN` is set in
`.env`, `make local-upgrade` and `make local-deploy` automatically generate overrides so
each service serves both its `${KIND_DOMAIN}` host (for access through an external reverse
proxy terminating TLS) and its `.neops.local` host (for `make config-hosts`). `storage.` is
declared alongside them but is not served until `neops-storage.enabled` is turned on.

The KIND cluster `kind` is shared with other projects; NeOps installs into namespace
`neops` and `make local-clean` only removes that namespace. Every target lives in
`.make-scripts/` and is listed in the `Makefile`.

The engine and gateway authenticate against core with an API key that only exists once
core is running: `make cms-token` mints it into the gitignored `cms_api_key.env`, and
`make local-upgrade` passes it along whenever that file exists. That same step mints a dev
JWT keypair into the gitignored `jwt/`, hands both PEMs to core with `--set-file` and the
public one to the engine, which verifies core's tokens with it; a real environment supplies
its own PEMs the same way.

## Network zones

A worker claims only the jobs of the network zones it lists in `NEOPS_WORKER_NETWORK_ZONES`.
Zones need core 2.4.0, engine 0.45.0 and worker 0.4.0 or later; older workers ignore the
variable. The umbrella's own worker is the central one: `values.yaml` sets
`neops-worker.env.NEOPS_WORKER_NETWORK_ZONES: default`. Keep it out of the neops-worker
chart's own defaults and out of any values file a remote site copies, so a zone release that
misses its own setting is refused rather than serving `default`.

Each other zone gets one more release of the neops-worker chart, pinned to nodes inside that
zone's network. Install it at the umbrella's worker version, since on 0.x the engine accepts
only workers of its own minor version and every zone's release upgrades with the umbrella:

```bash
kubectl label node <node-in-network-b> network-zone=zone-b
WORKER_VERSION=$(helm dependency list charts/neops | awk '$1 == "neops-worker" {print $2}')
helm install neops-worker-b oci://quay.io/zebbra/charts/neops-worker --namespace neops \
  --version "$WORKER_VERSION" \
  --set replicaCount=2 \
  --set 'imagePullSecrets[0].name=neops-quay-registry' \
  --set nodeSelector.network-zone=zone-b \
  --set env.URL_BLACKBOARD=http://neops-neops-workflow-engine:3030 \
  --set env.WORKER_NAME=neops-worker-b \
  --set env.NEOPS_WORKER_NETWORK_ZONES=zone-b
```

The namespace and the `neops-neops-workflow-engine` host follow from the umbrella's release
name and namespace, both `neops` here; adjust them if yours differ.

- **Several zones.** `--set` splits on commas, so escape them and single-quote the argument,
  or the shell drops the backslash: `--set 'env.NEOPS_WORKER_NETWORK_ZONES=default\,zone-b'`.
  List several zones on one worker only if their addresses don't overlap from that node.
- **Two workers per zone.** A rollback goes back to the forward job's zone, and the worker it
  needs is often the one that just died. A zone with one worker also holds up its runs during
  every restart of that worker. Hence `replicaCount=2` above; give the central worker the same
  with `--set neops-worker.replicaCount=2` on the umbrella.
- **Order.** Create the zone first, on the web client's Network zones page, which needs web
  client 6.1.0 and write on the `network-zones` permission element. The `networkZoneUpsert`
  mutation needs the same write, and Django admin works too. No worker needs to be up for
  that. A zone's workers are refused at registration while the zone doesn't exist. Once any
  zone besides `default` exists, a worker that lists no zones is refused at its next start.
- **Networking.** A zone's management ranges must not overlap the cluster's pod and service
  ranges as seen from that zone's nodes. Giving a remote site's nodes a network path to the
  engine's worker routes, which are unauthenticated, is the operator's job; this chart adds none.

## Upgrading core

Since core chart 2.3.0, core's post-upgrade migrate Job rebuilds the search indices this
core or this Elasticsearch version did not build. The first upgrade to such a core rebuilds all of
them, and search is down until the Job finishes. Helm's default `--timeout` (5m) is shorter than the
Job's default deadline (`neops-core.migrate.activeDeadlineSeconds`, 900 s), so on a real
inventory raise both, the timeout a few minutes above the deadline, and leave `--atomic` off for
this upgrade, for example
`helm upgrade ... --timeout 35m --set neops-core.migrate.activeDeadlineSeconds=1800`. Core's
release notes ("The rebuild runs on upgrade" in
[`docs/releases/v2.3.0.md`](https://github.com/zebbra/neops-core/blob/v2.3.0/docs/releases/v2.3.0.md#the-rebuild-runs-on-upgrade-and-search-is-down-while-it-runs))
cover sizing and the Job's log; going back is under "Going back to an
earlier release" there.
