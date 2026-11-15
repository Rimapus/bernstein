#!/usr/bin/env bash
# Create the poll-app secrets from .env.
# Usage: scripts/secrets.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ ! -f .env ]]; then
  echo ".env not found: copy .env.example to .env and fill it in" >&2
  exit 1
fi

set -a
. ./.env
set +a

namespace=poll-app

require() {
  [[ -n ${!1:-} ]] || { echo "$1 is empty: set it in .env" >&2; exit 1; }
}

apply_secret() {
  local name=$1
  shift
  kubectl -n "$namespace" create secret generic "$name" "$@" \
    --dry-run=client -o yaml | kubectl apply -f -
}

for var in REGISTRY_PULLER_PASSWORD REDIS_PASSWORD POSTGRES_DB POSTGRES_USER POSTGRES_PASSWORD; do
  require "$var"
done

kubectl apply -f kubernetes/namespace.yaml >/dev/null

registry=${REGISTRY:-$(scripts/inventory-host.sh registry):5000}

kubectl -n "$namespace" create secret docker-registry registry-credentials \
  --docker-server="$registry" \
  --docker-username=puller \
  --docker-password="$REGISTRY_PULLER_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "$namespace" patch serviceaccount default --type merge \
  -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}' >/dev/null

apply_secret redis-secret --from-literal=REDIS_PASSWORD="$REDIS_PASSWORD"
apply_secret postgres-secret \
  --from-literal=POSTGRES_DB="$POSTGRES_DB" \
  --from-literal=POSTGRES_USER="$POSTGRES_USER" \
  --from-literal=POSTGRES_PASSWORD="$POSTGRES_PASSWORD"

echo "Secrets ready in namespace $namespace."
