#!/bin/bash
set -euo pipefail
set -a; . ./.env; set +a
echo "$QUAY_TOKEN" | helm registry login quay.io --username "$QUAY_USER" --password-stdin
