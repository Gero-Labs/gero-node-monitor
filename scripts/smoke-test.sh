#!/usr/bin/env bash
#
# Smoke test: start the agent against a stub config and assert it enforces auth.
#
# This exists because the agent is installed onto SPO block producers by
# `curl … | bash` off the default branch, so whatever lands on main runs as
# root on other people's machines. The auth check is the thing most worth a
# regression test: a change that makes it fall open is invisible in review and
# silently exposes every operator who reinstalls.
#
# Runs with no cardano-node present. Endpoints that shell out to cardano-cli
# fail, which is fine — 401 is returned before any handler runs, and the
# authenticated case only needs a response that is not 401.

set -euo pipefail

PORT="${SMOKE_PORT:-12799}"
TOKEN="smoke-test-token-$$"
SERVER="${1:-gero-node-monitor-server.py}"

TMP="$(mktemp -d)"
export HOME="$TMP"
mkdir -p "$HOME/.gero-node-monitor"

# tunnel:false matters — CI must never open a public cloudflare tunnel.
cat > "$HOME/.gero-node-monitor/config.json" <<EOF
{
  "port": $PORT,
  "host": "127.0.0.1",
  "cardanoNodeSocket": "$TMP/node.socket",
  "cardanoCliPath": "/nonexistent/cardano-cli",
  "poolId": "pool1smoketest",
  "tunnel": false,
  "authToken": "$TOKEN"
}
EOF

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    # Reap it so the shell does not print its own "Terminated" line.
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP"
}
trap cleanup EXIT

python3 "$SERVER" > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

# Wait for the port rather than sleeping a fixed amount.
for _ in $(seq 1 50); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/health" 2>/dev/null; then break; fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: server exited during startup"
    cat "$TMP/server.log"
    exit 1
  fi
  sleep 0.2
done

fail=0
check() {
  local name="$1" want="$2" got="$3"
  if [ "$got" = "$want" ]; then
    echo "  ok   $name (HTTP $got)"
  else
    echo "  FAIL $name: got HTTP $got, want $want"
    fail=1
  fi
}

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

echo "Auth enforcement:"
check "no token is rejected"      401 "$(code "http://127.0.0.1:$PORT/versions")"
check "wrong token is rejected"   401 "$(code -H 'Authorization: Bearer wrong-token' "http://127.0.0.1:$PORT/versions")"
check "bare token is rejected"    401 "$(code -H "Authorization: $TOKEN" "http://127.0.0.1:$PORT/versions")"
check "correct token is accepted" 200 "$(code -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/versions")"

echo "CORS preflight:"
check "OPTIONS is unauthenticated" 204 "$(code -X OPTIONS "http://127.0.0.1:$PORT/status")"
if curl -s -i -X OPTIONS "http://127.0.0.1:$PORT/status" | grep -qi '^access-control-allow-headers:.*authorization'; then
  echo "  ok   preflight allows the Authorization header"
else
  echo "  FAIL preflight does not allow the Authorization header — browsers could not authenticate"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "server log:"
  sed 's/^/  /' "$TMP/server.log"
  exit 1
fi

echo
echo "smoke test passed"
