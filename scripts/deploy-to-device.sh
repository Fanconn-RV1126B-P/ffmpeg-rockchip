#!/bin/bash
#
# Deploy FFmpeg-Rockchip to RV1126B-P device
#
# Transfers the built install/ tree (or a release tarball) to the device
# via rsync/scp, then runs post-install steps.
#
# Usage:
#   ./scripts/deploy-to-device.sh [DEVICE_IP] [USER] [INSTALL_DIR]
#
# Examples:
#   ./scripts/deploy-to-device.sh <DEVICE_HOST_OR_IP>
#   ./scripts/deploy-to-device.sh <DEVICE_HOST_OR_IP> root /usr/local
#   DEVICE_IP=<DEVICE_HOST_OR_IP> ./scripts/deploy-to-device.sh
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ─────────────────────────────────────────────────────────────

DEVICE_IP="${1:-${DEVICE_IP:-}}"
DEVICE_USER="${2:-${DEVICE_USER:-root}}"
INSTALL_DIR="${3:-${INSTALL_DIR:-/usr/local}}"
INSTALL_SRC="${FFMPEG_PREFIX:-$REPO_ROOT/install}"

if [ -z "$DEVICE_IP" ]; then
  echo -e "${RED}✗ Device host/IP is required${NC}"
  echo "Usage: $0 <device-host-or-ip> [user] [install-dir]"
  exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FFmpeg-Rockchip Device Deployment"
echo "  Source : $INSTALL_SRC"
echo "  Target : ${DEVICE_USER}@${DEVICE_IP}:${INSTALL_DIR}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────

if [ ! -d "$INSTALL_SRC" ] || [ ! -f "$INSTALL_SRC/bin/ffmpeg" ]; then
    echo -e "${RED}✗ Built ffmpeg not found at: $INSTALL_SRC/bin/ffmpeg${NC}"
    echo ""
    echo "Run the build first:"
    echo "  source scripts/ffmpeg-rockchip-cross-compile-env.sh"
    echo "  ./configure ... && make -j\$(nproc) && make install"
    exit 1
fi

# Verify the binary is aarch64 (not accidentally deploying host binary)
if ! file "$INSTALL_SRC/bin/ffmpeg" | grep -q "ARM aarch64"; then
    echo -e "${RED}✗ $INSTALL_SRC/bin/ffmpeg is not an aarch64 binary!${NC}"
    file "$INSTALL_SRC/bin/ffmpeg"
    exit 1
fi

FFMPEG_SIZE=$(du -sh "$INSTALL_SRC/bin/ffmpeg" | cut -f1)
echo -e "${GREEN}✓ Binary ready:${NC} aarch64 ($FFMPEG_SIZE)"

# Check SSH connectivity
echo "Checking device connectivity..."
if ! ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -q \
    "${DEVICE_USER}@${DEVICE_IP}" exit 2>/dev/null; then
    echo -e "${RED}✗ Cannot connect to ${DEVICE_USER}@${DEVICE_IP}${NC}"
    echo ""
    echo "Check:"
    echo "  1. Device is powered on and on the network"
    echo "  2. IP address is correct (current: $DEVICE_IP)"
    echo "  3. SSH is enabled on device"
    echo ""
    echo "Usage: $0 <device-ip> [user] [install-dir]"
    exit 1
fi
echo -e "${GREEN}✓ Device reachable:${NC} ${DEVICE_USER}@${DEVICE_IP}"

# Check available disk space (need at least 30 MB)
AVAIL_MB=$(ssh "${DEVICE_USER}@${DEVICE_IP}" \
    "df -m ${INSTALL_DIR} 2>/dev/null || df -m / " \
    | awk 'NR==2{print $4}')
echo -e "${GREEN}✓ Available disk space on device:${NC} ${AVAIL_MB} MB"
if [ "${AVAIL_MB:-0}" -lt 30 ]; then
    echo -e "${RED}✗ Insufficient disk space (${AVAIL_MB} MB available, 30 MB needed)${NC}"
    exit 1
fi

# ── Sync binaries ─────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Syncing binaries...${NC}"
rsync -avz --progress \
    --exclude='*.a' \
    --exclude='pkgconfig/' \
    "$INSTALL_SRC/bin/" \
    "${DEVICE_USER}@${DEVICE_IP}:${INSTALL_DIR}/bin/"

# Also sync test script
if [ -f "$REPO_ROOT/scripts/test-on-device.sh" ]; then
  rsync -avz "$REPO_ROOT/scripts/test-on-device.sh" \
        "${DEVICE_USER}@${DEVICE_IP}:${INSTALL_DIR}/bin/ffmpeg-test.sh"
fi

# ── Post-install ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Running post-install on device...${NC}"
ssh "${DEVICE_USER}@${DEVICE_IP}" bash <<EOF
  set -e

  # Make sure binaries are executable
  chmod +x ${INSTALL_DIR}/bin/ffmpeg ${INSTALL_DIR}/bin/ffprobe 2>/dev/null || true
  [ -f "${INSTALL_DIR}/bin/ffmpeg-test.sh" ] && \
    chmod +x ${INSTALL_DIR}/bin/ffmpeg-test.sh || true

  # Add to PATH if not already there (via profile.d)
  if ! echo "\$PATH" | grep -q "${INSTALL_DIR}/bin"; then
    echo "export PATH=${INSTALL_DIR}/bin:\\\$PATH" > /etc/profile.d/ffmpeg.sh
    chmod +x /etc/profile.d/ffmpeg.sh
    echo "  Added ${INSTALL_DIR}/bin to PATH via /etc/profile.d/ffmpeg.sh"
  fi

  # Verify ffmpeg runs
  echo ""
  echo "=== FFmpeg Version ==="
  ${INSTALL_DIR}/bin/ffmpeg -version 2>&1 | head -5 || \
    { echo "ERROR: ffmpeg failed to run - check library dependencies"; exit 1; }

  echo ""
  echo "=== Hardware Codec Support ==="
  echo "MPP Decoders:"
  ${INSTALL_DIR}/bin/ffmpeg -hide_banner -decoders 2>/dev/null | \
    grep _rkmpp || echo "  none found"

  echo "MPP Encoders:"
  ${INSTALL_DIR}/bin/ffmpeg -hide_banner -encoders 2>/dev/null | \
    grep _rkmpp || echo "  none found"

  echo "RGA Filters:"
  ${INSTALL_DIR}/bin/ffmpeg -hide_banner -filters 2>/dev/null | \
    grep rkrga || echo "  none found"

  echo ""
  echo "=== Device Nodes ==="
  ls -la /dev/mpp_service /dev/rga 2>/dev/null || \
    echo "  WARNING: /dev/mpp_service or /dev/rga not found"
EOF

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Deployment complete!${NC}"
echo ""
echo "On the device, run:"
echo "  ${INSTALL_DIR}/bin/ffmpeg -version"
echo "  ${INSTALL_DIR}/bin/ffmpeg-test.sh   # full hardware test"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
