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

## The superuser's role

With `neops-core.superuser.enabled` (on in `values-kind.yaml`), core's migrate hook creates
the Django superuser. From core 2.4.0 the same hook gives it the Neops role
`neops-core.superuser.role` (default `admin`) on every install and upgrade:

- write on the scope `Global` and on the `network-zones` permission element, so the superuser
  can create zones (core's `manage.py bootstrap_admin_role`);
- the workflow `admin` profile (core's `manage.py grant_workflow_permissions`).

neops-docker-compose's `cms-init` runs the same two commands. Without the role, the superuser
can log in and then read and write nothing. The seed re-applies every grant on every install and
upgrade, so a grant removed from that role by hand comes back. If other users already hold a role
of this name, the seed leaves it alone and warns; set `neops-core.superuser.role` to a role only
the superuser holds.

Other users who create zones need write on `network-zones` in a role of their own: grant it in
Django admin under *Role permission elements*. Never work around a missing grant by starting a
site's workers with `default`: a site's worker that serves `default` reaches the default
network's addresses, with their devices' credentials, from inside the site's network.

## Network zones

A worker claims only the jobs of the network zones it lists in `NEOPS_WORKER_NETWORK_ZONES`;
the engine's [Network Zones](https://docs.neops.io/neops-workflow-engine/docs/20-workflows/45-network-zones/) page has the rules.
Zones need core 2.4.0, engine 0.46.0 and worker 0.5.0 or later; older workers ignore the
variable. The umbrella's own worker is the central one: `values.yaml` sets
`neops-worker.env.NEOPS_WORKER_NETWORK_ZONES: default`. Keep it out of the neops-worker
chart's own defaults and out of any values file a remote site copies, so a zone release that
misses its own setting is refused rather than serving `default`.

Each other zone gets one more release of the neops-worker chart, pinned to nodes inside that
zone's network. Install it at the umbrella's worker version, since on 0.x the engine accepts
only workers whose engine client is of its own minor, each worker release pins one client, and
every zone's release upgrades with the umbrella:

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

On KIND, run the zone's release on the worker image the umbrella's KIND values use, the
locally built one, instead of the Quay image the chart defaults to. Add these two flags to the
zone release's `helm install` above:

```bash
  --set image.repository=neops-worker-sdk \
  --set image.tag=cutting-edge
```

- **Several zones.** `--set` splits on commas, so escape them and single-quote the argument,
  or the shell drops the backslash: `--set 'env.NEOPS_WORKER_NETWORK_ZONES=default\,zone-b'`.
  List several zones on one worker only if their addresses don't overlap from that node.
- **Two workers per zone.** A rollback goes back to the forward job's zone, and the worker it
  needs is often the one that just died. A zone with one worker also holds up its runs during
  every restart of that worker. Hence `replicaCount=2` above; give the central worker the same
  with `--set neops-worker.replicaCount=2` on the umbrella. The developer-preview engine caps
  an installation at 2 workers, so a zones setup with more workers needs the licensed engine,
  the image the neops-workflow-engine chart defaults to.
- **Order.** Create the zone first, on the web client's Network zones page, which needs web
  client 6.1.0 and write on the `network-zones` permission element. The `networkZoneUpsert`
  mutation needs the same write, and Django admin works too. No worker needs to be up for
  that. A zone's workers are refused at registration while the zone doesn't exist. Once any
  zone besides `default` exists, a worker that lists no zones is refused at its next start, but
  only then: one already running keeps claiming `default` jobs. After creating the first zone,
  set `NEOPS_WORKER_NETWORK_ZONES` on every worker that lists none and restart it; the Monitor
  App's Workers page flags the workers that registered no zone list.
- **Retiring a site.** First move the zone's devices to another zone with
  `device_update_device`, or delete them. If the site is already unreachable, give that step
  `networkZone: { name: <a live zone>, override: true }`, or delete the devices in Django admin,
  which needs no worker; otherwise the step waits up to an hour for a worker that never comes
  and holds other runs meanwhile. Then `helm uninstall` the zone's worker release, and last
  delete the zone, on the Network zones page or in Django admin, once no workflow run names it.
- **Networking.** A zone's management ranges must not overlap the cluster's pod and service
  ranges as seen from that zone's nodes. Giving a remote site's nodes a network path to the
  engine's worker routes, which are unauthenticated, is the operator's job; this chart adds none.
  A zone routes jobs and authorizes nothing: every pod or host that reaches those routes can
  register for any zone, `default` included, and receive its devices' passwords. Restrict who
  reaches the engine, for example with a NetworkPolicy, and encrypt the path between sites,
  with the CNI's encryption or a VPN.

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

## Upgrading the engine to 0.45.0 or later

Engines before 0.45.0, 0.45.0-beta.1 included, ignore `POSTGRES_USER` and connect as `postgres`,
so an existing install's engine tables are owned by `postgres`. From 0.45.0 the engine connects as
`neops-workflow-engine.env.POSTGRES_USER`, which this chart sets to `neops`. Before
`helm upgrade`, on every install that ran an older engine:

1. Set `neops-workflow-engine.secrets.POSTGRES_PASSWORD` to the `neops` password,
   `postgresql.auth.password`, not `postgresql.auth.postgresPassword`.
2. Hand the engine's tables to `neops`: save the script from the engine's
   [upgrade docs](https://docs.neops.io/neops-workflow-engine/docs/50-deployment/10-configuration/#upgrading-an-engine-that-connected-as-postgres)
   as `owner-to-postgres-user.sql` and run it as `postgres` in the `neops-workflow` database:

   ```bash
   kubectl -n neops exec -i neops-postgresql-0 -c postgresql -- sh -c \
     'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" psql -h 127.0.0.1 -U postgres -d neops-workflow -v ON_ERROR_STOP=1 -v role=neops -f -' \
     < owner-to-postgres-user.sql
   ```

   The pod is `<release>-postgresql-0` in the umbrella's namespace. The old engine can keep running
   meanwhile, and running the script twice changes nothing.

Skip it and the upgraded engine refuses to start: its log says that it connects as `neops` while
`postgres` owns its tables, and names the script. It changes nothing: run the script, then restart
the engine. Skip step 1 instead, and it stops earlier, with
`password authentication failed for user "neops"`. The engine's
[upgrade docs](https://docs.neops.io/neops-workflow-engine/docs/50-deployment/10-configuration/#upgrading-an-engine-that-connected-as-postgres) have the rest.

### Going back to engine 0.44.1

Going back to the engine this chart pinned before, 0.44.1, crosses two engine minors. An engine
without zones ignores a worker's zones, so a zone's worker left polling it takes any zone's jobs,
and a 0.5 worker cannot read the jobs 0.44 hands out.

1. Let every run finish, and start no new ones. A job claimed by a worker you stop next fails as
   worker-offline after about 6 minutes, and its rollback finds no worker in that zone.
2. Scale every zone's worker release to 0, one command per zone release, and the umbrella's
   central worker too: it is a 0.5 worker, which cannot read the jobs 0.44 hands out. Step 6 brings
   it back at 0.3.0.

   ```bash
   kubectl -n neops scale deployment neops-worker-b --replicas=0
   kubectl -n neops scale deployment neops-neops-worker --replicas=0
   ```

3. Revert the 0.46 migrations from the 0.46 image, as the engine's
   [Going back to 0.45](https://docs.neops.io/neops-workflow-engine/docs/50-deployment/40-operations/#going-back-to-045)
   describes, with this chart's engine settings (`POSTGRES_USER` `neops` and its password), which
   own the tables since the upgrade. This also reverts 0.45's two migrations,
   `Migration20261102104651` and `Migration20261102113953`, whose revert deletes the rows of
   refused workers: the revert runs in name order, and both names sort after the zones migrations.
   0.44.1 applies neither again.

   The engine must be stopped, so there is no pod to `kubectl exec` into. Stop it, save that page's
   SQL as `going-back-0.45.sql` and run it, then run the down in a one-off pod from the 0.46 image, with the engine's pull secret,
   database settings and Secret (`<release>-neops-workflow-engine`, which holds
   `POSTGRES_PASSWORD`):

   ```bash
   kubectl -n neops scale deployment neops-neops-workflow-engine --replicas=0
   kubectl -n neops wait --for=delete pod --timeout=5m \
     -l app.kubernetes.io/name=neops-workflow-engine,app.kubernetes.io/instance=neops
   kubectl -n neops exec -i neops-postgresql-0 -c postgresql -- sh -c \
     'PGPASSWORD="$(cat /opt/bitnami/postgresql/secrets/postgres-password)" psql -h 127.0.0.1 -U postgres -d neops-workflow -v ON_ERROR_STOP=1 -f -' \
     < going-back-0.45.sql
   kubectl -n neops run engine-migrate-down --rm -i --restart=Never \
     --image=quay.io/zebbra/neops-workflow-engine:0.46.0 \
     --env=POSTGRES_HOST=neops-postgresql --env=POSTGRES_PORT=5432 --env=POSTGRES_USER=neops \
     --override-type=strategic --overrides='{"apiVersion": "v1", "spec": {
       "imagePullSecrets": [{"name": "neops-quay-registry"}],
       "containers": [{"name": "engine-migrate-down",
         "envFrom": [{"secretRef": {"name": "neops-neops-workflow-engine"}}]}]}}' \
     -- node -e 'const { MikroORM } = require("@mikro-orm/core");
   const config = require("./dist/neops-workflow-engine/src/mikro-orm.config").default;
   MikroORM.init(config).then(async orm => {
     await orm.getMigrator().down({ to: "Migration20261030184705" });
     await orm.close(true);
   });'
   ```

4. Set `neops-workflow-engine.secrets.POSTGRES_PASSWORD` back to the `postgres` password before
   step 6, since 0.44 always connects as `postgres`:

   ```bash
   kubectl -n neops get secret neops-postgresql -o jsonpath='{.data.postgres-password}' | base64 -d
   ```

   The secret is `<release>-postgresql`. The tables handed to `neops` need nothing: `postgres` is a
   superuser and reaches them as they are.
5. Take core's database back to 2.3.0 while the 2.4.0 core still runs, since step 6's chart pins
   core 2.3.0, which cannot run on 2.4.0's migrations. Stop core's worker and beat first, as step 1 of
   the Helm way back in core's
   [2.3.0 notes](https://github.com/zebbra/neops-core/blob/v2.3.0/docs/releases/v2.3.0.md#going-back-to-an-earlier-release)
   does. Then drain the log outbox, as "Going back" under "Log lines survive a log store outage" in
   core's [2.4.0 notes](https://github.com/zebbra/neops-core/blob/v2.4.0/docs/releases/v2.4.0.md#log-lines-survive-a-log-store-outage)
   says: run `log_store_status` until `rows` is 0. Last, undo `0206_network_zone`, which deletes
   every zone and every device's zone, as
   [Going back below 2.4.0](https://github.com/zebbra/neops-core/blob/v2.4.0/docs/releases/v2.4.0.md#going-back-below-240)
   in the same notes warns (note which devices are in which zone first), and `0205_log_outbox`:

   ```bash
   kubectl -n neops exec deploy/neops-neops-core -- /docker-entrypoint.sh ./manage.py log_store_status
   kubectl -n neops exec deploy/neops-neops-core -- /docker-entrypoint.sh ./manage.py migrate core 0204_merge_20261029_logging_develop
   ```

6. Upgrade the umbrella with this repo's chart at commit `6f93b5f` (umbrella 0.2.1), which pins
   core 2.3.0, engine 0.44.1, worker 0.3.0 and web client 6.0.1 together, so the central worker
   goes back with the engine. This repo has no tags and `main` pins the zones release, so check out
   that commit and upgrade from `charts/neops` with the values you installed with. That commit's
   README has no going-back section, so keep this one open on GitHub:

   ```bash
   git switch --detach 6f93b5f
   helm dependency update charts/neops
   helm upgrade neops charts/neops --namespace neops -f <your values file>  # plus any --set-file you installed with
   ```

Going forward again, switch this checkout back to the chart you go forward to (`git switch main`,
then `helm dependency update charts/neops`), and set `neops-workflow-engine.secrets.POSTGRES_PASSWORD`
back to the `neops` password first (undoing step 4), or the 0.46 engine fails with
`password authentication failed for user "neops"`. The zones are gone and every device is in
`default`, and the engine counts every worker that registered before the upgrade in `default`.
After the umbrella upgrade, restart the central worker, recreate the zones on the web client's
Network zones page, and move their devices back with runs, as core's
[Going back below 2.4.0](https://github.com/zebbra/neops-core/blob/v2.4.0/docs/releases/v2.4.0.md#going-back-below-240)
says. Then scale each zone release back up; a zone's workers are refused while their zone does not
exist. A zone release already on the umbrella's worker version needs no upgrade; otherwise upgrade
it with `--reuse-values`, since a plain `helm upgrade` resets its `NEOPS_WORKER_NETWORK_ZONES` and
the worker is refused at start:

```bash
kubectl -n neops rollout restart deployment neops-neops-worker
kubectl -n neops scale deployment neops-worker-b --replicas=2
```

The deployment names follow from the release names used above: `<release>-neops-worker` for the
umbrella's worker, and the release name for a zone's.
