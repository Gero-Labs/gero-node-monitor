#!/usr/bin/env bash
#
# Recompute the pinned revision and checksums in install.sh.
#
# Usage:
#   scripts/update-pins.sh <ref>     # any commit SHA, tag or branch
#   scripts/update-pins.sh           # defaults to the current origin/main SHA
#
# Checksums are taken from the bytes raw.githubusercontent actually serves at
# that revision, not from the local working copy — the local files may differ
# from what an operator would download, which is exactly the mismatch this is
# meant to catch.

set -euo pipefail

REPO="Gero-Labs/gero-node-monitor"
FILES=(gero-node-monitor.sh gero-node-monitor.service)
INSTALLER="$(dirname "$0")/../install.sh"

REF="${1:-}"
if [ -z "$REF" ]; then
  REF="$(git ls-remote "https://github.com/${REPO}.git" refs/heads/main | awk '{print $1}')"
  echo "No ref given, using current origin/main: $REF"
fi

# A branch name would defeat the point: the pin has to name something that
# cannot change under the operator's feet.
case "$REF" in
  main|master|HEAD)
    echo "Refusing to pin to '$REF' — a moving branch is not a pin." >&2
    echo "Pass a commit SHA or a tag." >&2
    exit 1
    ;;
esac

sha256_of_url() {
  if command -v sha256sum >/dev/null 2>&1; then
    curl -fsSL "$1" | sha256sum | awk '{print $1}'
  else
    curl -fsSL "$1" | shasum -a 256 | awk '{print $1}'
  fi
}

declare -a SUMS
for f in "${FILES[@]}"; do
  url="https://raw.githubusercontent.com/${REPO}/${REF}/${f}"
  sum="$(sha256_of_url "$url")"
  if [ -z "$sum" ]; then
    echo "Failed to fetch $url" >&2
    exit 1
  fi
  echo "  $f  $sum"
  SUMS+=("$sum")
done

# Portable in-place edit: GNU sed wants -i, BSD sed wants -i ''.
sed_i() {
  if sed --version >/dev/null 2>&1; then sed -i "$@"; else sed -i '' "$@"; fi
}

sed_i "s|^GERO_MONITOR_REF=\"\${GERO_MONITOR_REF:-.*}\"|GERO_MONITOR_REF=\"\${GERO_MONITOR_REF:-${REF}}\"|" "$INSTALLER"
sed_i "s|^SCRIPT_SHA256=\".*\"|SCRIPT_SHA256=\"${SUMS[0]}\"|" "$INSTALLER"
sed_i "s|^SERVICE_SHA256=\".*\"|SERVICE_SHA256=\"${SUMS[1]}\"|" "$INSTALLER"

echo
echo "install.sh now pins $REF"
grep -E '^(GERO_MONITOR_REF|SCRIPT_SHA256|SERVICE_SHA256)=' "$INSTALLER" | sed 's/^/  /'
