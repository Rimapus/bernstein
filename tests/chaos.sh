#!/usr/bin/env bash
# Redis chaos test: kill Redis, verify poll readiness fails, then recovers.
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

# Print poll's /readyz status from inside the pod; 0 on timeout.
poll_readyz() {
  kubectl -n "$NAMESPACE" exec deploy/poll -- python -c '
import urllib.request, urllib.error
try:
    print(urllib.request.urlopen("http://localhost/readyz", timeout=1).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception:
    print(0)' 2>/dev/null || echo 0
}

step "Baseline"
[[ $(poll_readyz) == 200 ]] || fail "poll is not ready before the test"
pass "poll /readyz 200"

step "Delete Redis"
kubectl -n "$NAMESPACE" delete pod redis-0 --wait=false >/dev/null
pass "redis-0 deleted"

step "Wait for poll readiness to fail"
deadline=$((SECONDS + 30))
while [[ $(poll_readyz) == 200 ]]; do
  ((SECONDS < deadline)) || fail "poll /readyz stayed 200 while Redis was down"
  sleep 0.5
done
pass "poll /readyz fails while Redis is down"

step "Wait for Redis"
kubectl -n "$NAMESPACE" rollout status statefulset/redis --timeout=120s >/dev/null ||
  fail "redis did not come back"
pass "redis back"

step "Wait for poll recovery"
deadline=$((SECONDS + TIMEOUT))
until [[ $(poll_readyz) == 200 ]]; do
  ((SECONDS < deadline)) || fail "poll /readyz did not recover"
  sleep 1
done
pass "poll /readyz 200 again"

step "Vote flow"
before=$(result_total) || fail "no scores from $RESULT_URL"
[[ $(cast_vote d) == 200 ]] || fail "vote rejected after recovery"
after=$(wait_for_total $((before + 1)))
((after >= before + 1)) || fail "vote after recovery not counted"
pass "votes flow again ($before -> $after)"
