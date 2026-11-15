#!/usr/bin/env bash
# Deploy the application stack with the requested image tag.
# Usage: TAG=<tag> [REGISTRY=<host>:<port>] scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z ${TAG:-} ]]; then
  echo "TAG is empty: pass TAG=<tag>" >&2
  exit 1
fi

REGISTRY=${REGISTRY:-$(scripts/inventory-host.sh registry):5000}
ROLLOUT_TIMEOUT=${ROLLOUT_TIMEOUT:-180s}
namespace=poll-app

echo "Deploying $TAG from $REGISTRY"
scripts/secrets.sh

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

cp -R kubernetes "$tmpdir/kubernetes"
cp poll-application/schema.sql "$tmpdir/kubernetes/postgres/schema.sql"

cat >"$tmpdir/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - kubernetes
images:
  - name: poll
    newName: $REGISTRY/poll
    newTag: $TAG
  - name: result
    newName: $REGISTRY/result
    newTag: $TAG
  - name: worker
    newName: $REGISTRY/worker
    newTag: $TAG
EOF

kubectl apply -k "$tmpdir"

for resource in \
  statefulset/redis \
  statefulset/postgres \
  deployment/poll \
  deployment/result \
  deployment/worker; do
  kubectl -n "$namespace" rollout status "$resource" --timeout="$ROLLOUT_TIMEOUT"
done

echo "Deployed $TAG."
