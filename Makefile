init:
	.make-scripts/init.sh
local-deploy:
	.make-scripts/local-deploy.sh
clean-deploy:
	.make-scripts/local-clean.sh
	.make-scripts/local-deploy.sh
local-clean:
	.make-scripts/local-clean.sh
local-upgrade:
	.make-scripts/local-upgrade.sh
local-restart-pods:
	.make-scripts/local-restart-pods.sh
lock-dependencies:
	helm dependency build charts/neops/
list-kubectl-status:
	kubectl describe deployment
	kubectl describe svc
test:
	$(MAKE) clean-deploy
config-hosts:
	.make-scripts/config-hosts.sh