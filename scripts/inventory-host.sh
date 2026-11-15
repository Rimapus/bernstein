#!/usr/bin/env bash
# Print the ansible_host of the first host in an inventory group.
set -euo pipefail
cd "$(dirname "$0")/.."

group=${1:-}
if [[ -z $group ]]; then
  echo "usage: $0 <group>" >&2
  exit 2
fi

inventory=ansible/inventory/hosts.ini
[[ -f $inventory ]] || { echo "inventory not found: $inventory" >&2; exit 1; }

host=$(awk -v group="$group" '
  $0 == "[" group "]" { found=1; next }
  /^\[/ { found=0 }
  found && /ansible_host=/ {
    sub(/^.*ansible_host=/, "")
    print
    exit
  }
' "$inventory")

[[ -n $host ]] || { echo "no ansible_host in group '$group'" >&2; exit 1; }
echo "$host"
