#!/usr/bin/env bash
# Smoke test: workloads ready, poll serves a vote, result shows it.
# Usage: [SKIP_K8S=1] tests/smoke.sh
set -euo pipefail
cd "$(dirname "$0")"
source ./lib.sh

step "Workloads"
if [[ ${SKIP_K8S:-0} != 1 ]]; then
  for workload in \
    deployment/poll \
    deployment/worker \
    deployment/result \
    statefulset/redis \
    statefulset/postgres; do
    kubectl -n "$NAMESPACE" rollout status "$workload" --timeout=60s >/dev/null ||
      fail "$workload is not ready"
    pass "$workload ready"
  done
fi

step "Poll"
page=$("${CURL[@]}" "$POLL_URL/") || fail "GET $POLL_URL/ failed"
[[ $page == *'name="vote"'* ]] || fail "poll page has no vote buttons"
pass "GET / serves the vote page"

step "Result"
before=$(result_total) || fail "no scores from $RESULT_URL over Socket.IO"
pass "Socket.IO session receives scores (total $before)"

step "Vote flow"
code=$(cast_vote b)
[[ $code == 200 ]] || fail "POST vote returned $code"
pass "POST vote=b accepted"
after=$(wait_for_total $((before + 1)))
((after >= before + 1)) || fail "result still shows $after votes after ${TIMEOUT}s"
pass "result shows the vote ($before -> $after)"

pass "smoke test passed"
