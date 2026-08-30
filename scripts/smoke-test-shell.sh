#!/usr/bin/env bash
#
# Smoke test for gero-node-monitor.sh — the socat-based agent.
#
# This is the one install.sh actually places on a producer and the one the
# systemd unit runs, so it is the implementation most worth testing. It had no
# coverage at all until now.
#
# Requires socat and jq. cardano-cli is not needed: 401s are returned before any
# handler runs, and the authenticated case only needs a response that is not a
# 401.

set -uo pipefail

PORT="${SHELL_SMOKE_PORT:-12831}"
TOKEN="shell-smoke-token-$$"
AGENT="${1:-gero-node-monitor.sh}"
AGENT="$(cd "$(dirname "$AGENT")" && pwd)/$(basename "$AGENT")"

# Skipping is a convenience for machines without socat, but a silent skip in CI
# would look identical to a pass. SHELL_SMOKE_REQUIRE=1 turns a missing
# dependency into a failure; CI sets it.
for dep in socat jq curl; do
  if ! command -v "$dep" >/dev/null 2>&1; then
    if [ "${SHELL_SMOKE_REQUIRE:-0}" = "1" ]; then
      echo "FAIL: $dep not installed and SHELL_SMOKE_REQUIRE=1"
      exit 1
    fi
    echo "SKIP: $dep not installed"
    exit 0
  fi
done

TMP="$(mktemp -d)"
export HOME="$TMP"
mkdir -p "$HOME/.gero-node-monitor"

SERVER_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && wait "$SERVER_PID" 2>/dev/null || true
  pkill -f "TCP-LISTEN:${PORT}" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

write_config() {
  local host="$1" token="$2"
  cat > "$HOME/.gero-node-monitor/config.json" <<EOF
{
  "port": $PORT,
  "host": "$host",
  "cardanoNodeSocket": "$TMP/node.socket",
  "cardanoCliPath": "/nonexistent/cardano-cli",
  "cncliPath": "/nonexistent/cncli",
  "vrfSkeyPath": "/nonexistent/vrf.skey",
  "poolId": "pool1smoketest",
  "genesisFile": "/nonexistent/genesis.json",
  "byronGenesisFile": "/nonexistent/byron.json",
  "network": "mainnet",
  "dbPath": "/nonexistent/cncli.db",
  "allowedOrigins": ["*"],
  "authToken": "$token"
}
EOF
}

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
code() { curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$@"; }

# ── Auth enforcement over a real socat listener ──────────────────────────────
write_config 127.0.0.1 "$TOKEN"
bash "$AGENT" --start > "$TMP/server.log" 2>&1 &
SERVER_PID=$!

# socat writes its own errors to the agent's monitor.log, not to stdout, so a
# server that dies on startup otherwise looks identical to one that is merely
# slow — the loop just spins out and every request comes back 000.
ready=0
for _ in $(seq 1 60); do
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:$PORT/health" 2>/dev/null; then
    ready=1; break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "FAIL: agent exited during startup"
    echo "startup log:";  sed 's/^/  /' "$TMP/server.log" 2>/dev/null
    echo "monitor.log:";  sed 's/^/  /' "$HOME/.gero-node-monitor/monitor.log" 2>/dev/null
    exit 1
  fi
  sleep 0.25
done
if [ "$ready" -ne 1 ]; then
  echo "FAIL: agent never accepted a connection on port $PORT"
  echo "startup log:";  sed 's/^/  /' "$TMP/server.log" 2>/dev/null
  echo "monitor.log:";  sed 's/^/  /' "$HOME/.gero-node-monitor/monitor.log" 2>/dev/null
  echo "socat version:"; socat -V 2>&1 | head -2 | sed 's/^/  /'
  echo "listeners:";     (ss -ltnp 2>/dev/null || netstat -an 2>/dev/null | grep LISTEN) | head -10 | sed 's/^/  /'
  exit 1
fi

echo "Auth enforcement:"
check "no token is rejected"      401 "$(code "http://127.0.0.1:$PORT/health")"
check "wrong token is rejected"   401 "$(code -H 'Authorization: Bearer wrong' "http://127.0.0.1:$PORT/health")"
check "bare token is rejected"    401 "$(code -H "Authorization: $TOKEN" "http://127.0.0.1:$PORT/health")"
check "correct token is accepted" 200 "$(code -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:$PORT/health")"

echo "CORS preflight:"
check "OPTIONS is unauthenticated" 204 "$(code -X OPTIONS "http://127.0.0.1:$PORT/health")"

kill "$SERVER_PID" 2>/dev/null || true
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
pkill -f "TCP-LISTEN:${PORT}" 2>/dev/null || true

# ── Bind gate ────────────────────────────────────────────────────────────────
# Binding a routable address with no token is what served /leader-schedule to
# anything that could reach the box. Loopback with no token stays allowed.
echo "Bind gate:"
write_config 0.0.0.0 ""
bash "$AGENT" --start > "$TMP/bind.log" 2>&1
check "0.0.0.0 with empty authToken is refused" 1 "$?" "exit"
if grep -q "Refusing to bind" "$TMP/bind.log"; then
  echo "  ok   refusal explains itself"
else
  echo "  FAIL refusal message missing"
  fail=1
fi

write_config 127.0.0.1 ""
bash "$AGENT" --start > "$TMP/loop.log" 2>&1 &
SERVER_PID=$!
sleep 2
if kill -0 "$SERVER_PID" 2>/dev/null; then
  echo "  ok   loopback with no token still starts"
else
  echo "  FAIL loopback with no token was refused — that is a usable local setup"
  fail=1
fi

if [ "$fail" -ne 0 ]; then
  echo
  echo "server log:";  sed 's/^/  /' "$TMP/server.log" 2>/dev/null | head -20
  echo "monitor.log:"; sed 's/^/  /' "$HOME/.gero-node-monitor/monitor.log" 2>/dev/null | head -20
  echo "bind log:";    sed 's/^/  /' "$TMP/bind.log"   2>/dev/null | head -20
  exit 1
fi

echo
echo "shell agent smoke test passed"
