#!/usr/bin/env bash
#
# Assert that install.sh's pinned revision still serves files matching the
# checksums it carries. A drift here means operators would hit a checksum
# failure on install, so it is worth catching in CI rather than in the field.

set -euo pipefail

REPO="Gero-Labs/gero-node-monitor"
INSTALLER="$(dirname "$0")/../install.sh"

ref=$(grep -oE '^GERO_MONITOR_REF="\$\{GERO_MONITOR_REF:-[^}]*\}"' "$INSTALLER" | sed 's/.*:-//; s/}"//')
script_want=$(grep -oE '^SCRIPT_SHA256="[0-9a-f]*"' "$INSTALLER" | cut -d'"' -f2)
service_want=$(grep -oE '^SERVICE_SHA256="[0-9a-f]*"' "$INSTALLER" | cut -d'"' -f2)

if [ -z "$ref" ] || [ -z "$script_want" ] || [ -z "$service_want" ]; then
  echo "FAIL: could not read pins out of install.sh"
  exit 1
fi

case "$ref" in
  main|master|HEAD) echo "FAIL: install.sh pins the moving ref '$ref'"; exit 1 ;;
esac

echo "Pinned revision: $ref"

sum_url() { curl -fsSL "$1" | sha256sum | awk '{print $1}'; }

fail=0
check_pin() {
  local file="$1" want="$2"
  local got
  got="$(sum_url "https://raw.githubusercontent.com/${REPO}/${ref}/${file}")"
  if [ "$got" = "$want" ]; then
    echo "  ok   $file"
  else
    echo "  FAIL $file"
    echo "       pinned:  $want"
    echo "       served:  $got"
    fail=1
  fi
}

check_pin gero-node-monitor.sh "$script_want"
check_pin gero-node-monitor.service "$service_want"

[ "$fail" -eq 0 ] || { echo; echo "Run scripts/update-pins.sh <ref> to refresh."; exit 1; }
echo "installer pins verified"
