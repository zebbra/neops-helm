#!/bin/bash
set -e
# Define the desired host entries
entries=(
  "127.0.0.1 neops.local"
  "127.0.0.1 cms.neops.local"
  "127.0.0.1 docs.neops.local"
  "127.0.0.1 doc.neops.local"
  "127.0.0.1 workflow-engine.neops.local"
)

hosts_file="/etc/hosts"

# Iterate over each entry
for entry in "${entries[@]}"; do
  # Check if the entry already exists in /etc/hosts
  if ! grep -qF "$entry" ${hosts_file}; then
    # Append the entry to /etc/hosts
    echo "$entry" | sudo tee -a ${hosts_file} > /dev/null
  fi
done