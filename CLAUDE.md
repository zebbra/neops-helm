# neops-helm

Read AGENTS.md for full project context.

## Branch Workflow

Branch from `main`. This repo has no CI pipeline -- changes are validated via `helm lint` and `helm template` locally.

## Quick Reference

- Three charts: `charts/neops/`, `charts/neops-web-client/`, `charts/carbon-angular-storybook/`
- Environment overlays: `charts/<chart>/environments/`
- Sub-chart archives: `charts/neops/charts/*.tgz`
- Template helpers: `charts/neops/templates/_helpers.tpl`
- Secrets use `lookup` to preserve existing values on upgrade -- do not restructure without understanding this
