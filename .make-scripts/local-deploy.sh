#!/bin/bash
set -euo pipefail
.make-scripts/cluster-up.sh
.make-scripts/local-upgrade.sh
.make-scripts/cms-token.sh
.make-scripts/local-upgrade.sh
