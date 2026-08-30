#!/usr/bin/env bash
# ============================================================================
# Gero Node Monitor — Quick Install Script
# ============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
echo "  ╔═══════════════════════════════════════╗"
echo "  ║       Gero Node Monitor v1.0.0        ║"
echo "  ║   Cardano SPO Monitoring Agent        ║"
echo "  ╚═══════════════════════════════════════╝"
echo -e "${NC}"

# Check prerequisites
echo "Checking prerequisites..."

for cmd in jq socat curl; do
  if ! command -v $cmd &>/dev/null; then
    echo -e "${RED}Missing: ${cmd}${NC}"
    echo "Install with: sudo apt install ${cmd}"
    exit 1
  fi
done

if ! command -v cardano-cli &>/dev/null; then
  echo -e "${RED}cardano-cli not found${NC}"
  exit 1
fi

echo -e "${GREEN}Prerequisites OK${NC}"

# Download
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="${HOME}/.gero-node-monitor"

# Pinned revision, with the SHA-256 of each file as fetched at that revision.
#
# This used to install from `main`, which meant whatever was on the default
# branch at that moment got sudo-copied into /usr/local/bin and run as a
# systemd unit. A bad merge, or a push by anyone with write access, reached
# every producer that installed or reinstalled afterwards.
#
# A commit SHA is used rather than a tag because a tag can be moved, which
# would reintroduce exactly the mutability being removed here. The checksums
# are the real guarantee either way: point GERO_MONITOR_REF at anything you
# like, but if the bytes do not match, the install stops.
#
# To move the pin: update GERO_MONITOR_REF, then run scripts/update-pins.sh
# to recompute the two checksums below.
GERO_MONITOR_REF="${GERO_MONITOR_REF:-2c9273429d2ff72ec4e31e4f6eab35d8b9082e52}"
SCRIPT_SHA256="787301e0814dd6c598670af2988e3963341b2e057c62267b6d18e33a3133232b"
SERVICE_SHA256="1c98d8d005a82024786b3b7aac242c23061462a5840fc07b6915ce2810be94d1"

RAW_BASE="https://raw.githubusercontent.com/Gero-Labs/gero-node-monitor/${GERO_MONITOR_REF}"
SCRIPT_URL="${RAW_BASE}/gero-node-monitor.sh"
SERVICE_URL="${RAW_BASE}/gero-node-monitor.service"

# Verify before anything is placed on the system. Downloads land in a temp dir
# owned by this script, are checked, and only then moved into place with sudo:
# a file that fails verification never reaches /usr/local/bin at all.
TMP_DL="$(mktemp -d)"
trap 'rm -rf "$TMP_DL"' EXIT

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

fetch_verified() {
  local url="$1" dest="$2" want="$3" name="$4"
  if ! curl -fsSL "$url" -o "$dest"; then
    echo -e "${RED}Download failed: ${name}${NC}"
    echo "  from ${url}"
    exit 1
  fi
  local got
  got="$(sha256_of "$dest")"
  if [[ "$got" != "$want" ]]; then
    echo -e "${RED}Checksum mismatch for ${name} - refusing to install.${NC}"
    echo "  expected: ${want}"
    echo "  actual:   ${got}"
    echo ""
    echo "The file served does not match what this installer was built against."
    echo "Do not work around this. Report it at:"
    echo "  https://github.com/Gero-Labs/gero-node-monitor/issues"
    exit 1
  fi
}

echo "Installing to ${INSTALL_DIR}..."
echo "Revision: ${GERO_MONITOR_REF}"

fetch_verified "$SCRIPT_URL" "${TMP_DL}/gero-node-monitor.sh" "$SCRIPT_SHA256" "gero-node-monitor.sh"
sudo install -m 0755 "${TMP_DL}/gero-node-monitor.sh" "${INSTALL_DIR}/gero-node-monitor.sh"

echo -e "${GREEN}Installed gero-node-monitor.sh (checksum verified)${NC}"

# Create config
echo ""
echo "Creating configuration..."
"${INSTALL_DIR}/gero-node-monitor.sh" --config

# Install systemd service
echo ""
read -p "Install as systemd service? (y/N) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
  fetch_verified "$SERVICE_URL" "${TMP_DL}/gero-node-monitor.service" "$SERVICE_SHA256" "gero-node-monitor.service"
  sudo install -m 0644 "${TMP_DL}/gero-node-monitor.service" /etc/systemd/system/gero-node-monitor.service

  # Update service file with current user
  sudo sed -i "s/User=cardano/User=$(whoami)/" /etc/systemd/system/gero-node-monitor.service
  sudo sed -i "s/Group=cardano/Group=$(id -gn)/" /etc/systemd/system/gero-node-monitor.service

  sudo systemctl daemon-reload
  sudo systemctl enable gero-node-monitor

  echo -e "${GREEN}Systemd service installed${NC}"
  echo ""
  echo "Start with:  sudo systemctl start gero-node-monitor"
  echo "Logs:        journalctl -u gero-node-monitor -f"
else
  echo ""
  echo "Start manually:  gero-node-monitor.sh --start"
fi

echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "Edit config:  ${GREEN}${CONFIG_DIR}/config.json${NC}"
echo -e "Default port: ${GREEN}12798${NC}"
echo ""
echo "In Gero Wallet → Pool Operator → Node Monitor:"
echo -e "  Enter URL:  ${GREEN}http://your-node-ip:12798${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
