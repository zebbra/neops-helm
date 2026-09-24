include .make_scripts/project-infrastructure/project-infrastructure-makefile
# This includes make: sync-infrastructure-assets, github_autodelete_merged_branches, github_set_branch_protections and github_set_default_branch
include .make_scripts/release-management/release-management-makefile
# This includes make: tag-major, tag-major-beta, tag-minor, tag-minor-beta, tag-patch, tag-patch-beta, tag-latest-beta, tag-major-minor-ruleset, hard-reset-tags, check-for-release and sync-release-assets.
# NeOps umbrella chart + local KIND loop. Every target is a thin wrapper over
# .make-scripts/<target>.sh. The KIND cluster `kind` is shared with other
# projects: NeOps lives in namespace `neops` and never deletes the cluster.
#
# First time:   cp .env.dist .env   (QUAY_USER / QUAY_TOKEN), then
#               `make deploy-cutting-edge` from the workspace root (builds the
#               working tree) or `make local-deploy` here (pulls from Quay),
#               and `make config-hosts` once the release is up.

export KIND_CLUSTER ?= kind
export NAMESPACE    ?= neops

.PHONY: init cluster-up local-deploy local-upgrade cms-token local-clean clean-deploy lock-dependencies config-hosts list-kubectl-status

init:
	.make-scripts/init.sh
# Ensure cluster + ingress + storage class + namespace exist. Idempotent, installs no chart.
cluster-up:
	.make-scripts/cluster-up.sh
# cluster-up, install, mint the CMS token, install again with it.
local-deploy:
	.make-scripts/local-deploy.sh
# helm upgrade --install with values-kind.yaml (+ the token from cms_api_key.env when present).
local-upgrade:
	.make-scripts/local-upgrade.sh
# Mint the engine/gateway API key on the running core into cms_api_key.env.
cms-token:
	.make-scripts/cms-token.sh
# Uninstall the release and drop the namespace (and its PVCs). Keeps the cluster.
local-clean:
	.make-scripts/local-clean.sh
clean-deploy:
	.make-scripts/local-clean.sh
	.make-scripts/local-deploy.sh
# Refresh Chart.lock + charts/ from the registries (needs `make init` once).
lock-dependencies:
	helm dependency update charts/neops
	helm dependency build charts/neops
# Point the deployed release's .local hosts at 127.0.0.1. Needs the release to exist.
config-hosts:
	.make-scripts/config-hosts.sh
list-kubectl-status:
	kubectl -n $(NAMESPACE) describe deployment
	kubectl -n $(NAMESPACE) describe svc
