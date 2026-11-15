# Shared helpers for the test scripts. Source this file.

POLL_URL=${POLL_URL:-https://poll.bernstein.local}
RESULT_URL=${RESULT_URL:-https://result.bernstein.local}
CACERT=${CACERT:-$HOME/.kube/bernstein-ingress-ca.crt}
NAMESPACE=${NAMESPACE:-poll-app}
TIMEOUT=${TIMEOUT:-60}

CURL=(curl -sS --max-time 10)
if [[ $POLL_URL == https://* && -f $CACERT ]]; then
  CURL+=(--cacert "$CACERT")
fi

add_resolve() {
  local url=$1 hostport host port
  hostport=${url#*://}
  hostport=${hostport%%/*}
  host=${hostport%%:*}
  port=${hostport##*:}
  if [[ $port == "$hostport" ]]; then
    [[ $url == https://* ]] && port=443 || port=80
  fi
  CURL+=(--resolve "$host:$port:$INGRESS_IP")
}

if [[ -n ${INGRESS_IP:-} ]]; then
  add_resolve "$POLL_URL"
  add_resolve "$RESULT_URL"
fi

pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n%s\n' "$*"; }

# Read the vote total from result over a Socket.IO polling session.
result_total() {
  local jar sid body
  jar=$(mktemp)
  sid=$("${CURL[@]}" -c "$jar" "$RESULT_URL/socket.io/?EIO=4&transport=polling" |
    sed -n 's/.*"sid":"\([^"]*\)".*/\1/p')
  if [[ -z $sid ]]; then
    rm -f "$jar"
    return 1
  fi
  "${CURL[@]}" -b "$jar" -c "$jar" -X POST --data '40' \
    "$RESULT_URL/socket.io/?EIO=4&transport=polling&sid=$sid" >/dev/null
  for _ in {1..5}; do
    body=$("${CURL[@]}" -b "$jar" -c "$jar" \
      "$RESULT_URL/socket.io/?EIO=4&transport=polling&sid=$sid")
    if [[ $body == *'"scores"'* ]]; then
      rm -f "$jar"
      grep -o '\\"[abcd]\\":[0-9]*' <<<"$body" | head -4 |
        awk -F: '{ total += $2 } END { print total + 0 }'
      return 0
    fi
  done
  rm -f "$jar"
  return 1
}

# Cast one vote as a new voter.
cast_vote() {
  "${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST --data "vote=${1:-a}" "$POLL_URL/"
}

# Wait until result shows at least $1 votes; print the last total.
wait_for_total() {
  local want=$1 deadline=$((SECONDS + TIMEOUT)) total=0
  while ((SECONDS < deadline)); do
    total=$(result_total || echo 0)
    ((total >= want)) && break
    sleep 2
  done
  echo "$total"
}
