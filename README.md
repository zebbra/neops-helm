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

## Upgrading core

With core chart 2.2.1-beta.9, which this chart pins, core's post-upgrade migrate Job rebuilds the search indices this
core or this Elasticsearch version did not build. The first upgrade to it rebuilds all of them,
and search is down until the Job finishes. Helm's default `--timeout` (5m) is shorter than the
Job's default deadline (`neops-core.migrate.activeDeadlineSeconds`, 900 s), so on a real
inventory raise both, the timeout a few minutes above the deadline, and leave `--atomic` off for
this upgrade, for example
`helm upgrade ... --timeout 35m --set neops-core.migrate.activeDeadlineSeconds=1800`. Core's
release notes ("The rebuild runs on upgrade" in
[`docs/releases/unreleased.md`](https://github.com/zebbra/neops-core/blob/develop/docs/releases/unreleased.md#the-rebuild-runs-on-upgrade-and-search-is-down-while-it-runs)
until 2.2.1 is released) cover sizing and the Job's log; going back is under "Going back to an
earlier release" there.
