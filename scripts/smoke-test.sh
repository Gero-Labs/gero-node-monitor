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
write_config() {
  local tunnel="$1" token="$2"
  cat > "$HOME/.gero-node-monitor/config.json" <<EOF
{
  "port": $PORT,
  "host": "127.0.0.1",
  "cardanoNodeSocket": "$TMP/node.socket",
  "cardanoCliPath": "/nonexistent/cardano-cli",
  "poolId": "pool1smoketest",
  "tunnel": $tunnel,
  "authToken": "$token"
}
EOF
}

write_config false "$TOKEN"

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
  local name="$1" want="$2" got="$3" unit="${4:-HTTP}"
  if [ "$got" = "$want" ]; then
    echo "  ok   $name ($unit $got)"
  else
    echo "  FAIL $name: got $unit $got, want $want"
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

# The agent must refuse to publish a public tunnel with no token. This is the
# regression that matters most: the combination of an open tunnel and an empty
# authToken is what put /leader-schedule on the public internet.
echo "Tunnel gate:"
kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""

# Safety rail. If the gate ever regresses, the agent would fall through to
# actually starting a tunnel — and on a missing `cloudflared` it tries to
# curl one into /usr/local/bin, which on a CI runner with passwordless sudo
# means CI could publish a real public tunnel. A stub `cloudflared` that exits
# silently makes that impossible: no binary is fetched, no URL is produced, and
# so nothing is registered with the backend either.
mkdir -p "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' > "$TMP/bin/cloudflared"
chmod +x "$TMP/bin/cloudflared"

write_config true ""
set +e
# Bounded: a regressed gate blocks in serve_forever instead of exiting, and a
# hung job that eventually times out reads as infrastructure flake rather than
# as the regression it is.
PATH="$TMP/bin:$PATH" python3 "$SERVER" > "$TMP/tunnel.log" 2>&1 &
gate_pid=$!
gate_rc=""
for _ in $(seq 1 200); do
  if ! kill -0 "$gate_pid" 2>/dev/null; then
    wait "$gate_pid"; gate_rc=$?
    break
  fi
  sleep 0.25
done
if [ -z "$gate_rc" ]; then
  kill "$gate_pid" 2>/dev/null || true
  wait "$gate_pid" 2>/dev/null || true
  gate_rc="timeout"
fi
set -e

check "tunnel with empty authToken is refused" 1 "$gate_rc" "exit"
if grep -q "Refusing to open a public tunnel" "$TMP/tunnel.log"; then
  echo "  ok   refusal explains itself"
else
  echo "  FAIL refusal message missing — an operator would not know why it exited"
  fail=1
fi
if grep -qi "trycloudflare\|Starting Cloudflare tunnel" "$TMP/tunnel.log"; then
  echo "  FAIL a tunnel was started despite the missing token"
  fail=1
else
  echo "  ok   no tunnel was started"
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "server log:"
  sed 's/^/  /' "$TMP/server.log"
  if [ -f "$TMP/tunnel.log" ]; then
    echo "tunnel-gate log:"
    sed 's/^/  /' "$TMP/tunnel.log"
  fi
  exit 1
fi

echo
echo "smoke test passed"
