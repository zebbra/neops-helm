# neops-helm

Umbrella Helm chart for the NeOps platform plus a local KIND loop.

`charts/neops` composes the NeOps services as OCI subcharts from
`oci://quay.io/zebbra/charts` (each service repo owns and publishes its own chart under
`chart/<name>/` on every tag) together with Bitnami `postgresql`, `redis`,
`elasticsearch` and `minio`. `values.yaml` holds in-cluster wiring only; every credential
comes from an environment values file. `values-kind.yaml` is the KIND environment: all
credentials are `unsafe`, images are the locally built `cutting-edge` tags, and every
service is published under both a public `*.neops.lerena.cloud` name and a `*.neops.local`
one.

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

The KIND values publish `neops.lerena.cloud` and the `cms`, `engine`, `workflows` and
`gateway` subdomains through an external proxy that terminates TLS, so the charts themselves
serve plain HTTP and carry no `tls:` section. Each has a `.local` twin for the offline path.
`storage.` is declared alongside them but is not served until `neops-storage.enabled` is
turned on.

The KIND cluster `kind` is shared with other projects; NeOps installs into namespace
`neops` and `make local-clean` only removes that namespace. Every target lives in
`.make-scripts/` and is listed in the `Makefile`.

The engine and gateway authenticate against core with an API key that only exists once
core is running: `make cms-token` mints it into the gitignored `cms_api_key.env`, and
`make local-upgrade` passes it along whenever that file exists. That same step mints a dev
JWT keypair into the gitignored `jwt/` and hands both PEMs to core with `--set-file`; a real
environment supplies its own PEMs the same way.
