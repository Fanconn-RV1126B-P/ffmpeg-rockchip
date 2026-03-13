#!/bin/bash
#
# deploy-to-device.sh
# Deploy a locally-built FFmpeg-Rockchip tree to an RV1126B-P device.
#
# NOTE: This script is for LOCAL builds only (i.e. you ran configure +
# make yourself using the SDK toolchain). To install the pre-built CI
# binary instead, use: sh scripts/install-ffmpeg-rv1126b.sh
#
# Usage:
#   ./scripts/deploy-to-device.sh [DEVICE_IP] [USER] [INSTALL_DIR]
#
# Environment variables (override prompts):
#   DEVICE_IP      device IP or hostname
#   DEVICE_USER    SSH user (default: root)
#   FFMPEG_PREFIX  path to local build install/ directory

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { printf "${BLUE}[+]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error()   { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

# ── Parameters ─────────────────────────────────────────────────────────
DEVICE_IP="${1:-${DEVICE_IP:-}}"
DEVICE_USER="${2:-${DEVICE_USER:-root}}"
INSTALL_DIR="${3:-${INSTALL_DIR:-/usr/local}}"
INSTALL_SRC="${FFMPEG_PREFIX:-$REPO_ROOT/install}"

if [ -z "$DEVICE_IP" ]; then
    printf "\n${YELLOW}Enter device IP address or hostname: ${NC}"
    read -r DEVICE_IP
    [ -n "$DEVICE_IP" ] || error "Device IP is required"
fi

printf "\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
printf "  FFmpeg-Rockchip Device Deployment (local build)\n"
printf "  Source : %s\n" "$INSTALL_SRC"
printf "  Target : %s@%s:%s\n" "$DEVICE_USER" "$DEVICE_IP" "$INSTALL_DIR"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n\n"

# ── Pre-flight ─────────────────────────────────────────────────────────
if [ ! -d "$INSTALL_SRC" ] || [ ! -f "$INSTALL_SRC/bin/ffmpeg" ]; then
    error "Built ffmpeg not found at: $INSTALL_SRC/bin/ffmpeg

Run the build first:
  source scripts/ffmpeg-rockchip-cross-compile-env.sh
  ./configure ... && make -j\$(nproc) && make install"
fi

if ! file "$INSTALL_SRC/bin/ffmpeg" | grep -q "ARM aarch64"; then
    error "$INSTALL_SRC/bin/ffmpeg is not an aarch64 binary!
$(file "$INSTALL_SRC/bin/ffmpeg")"
fi

FFMPEG_SIZE=$(du -sh "$INSTALL_SRC/bin/ffmpeg" | cut -f1)
success "Binary ready: aarch64 ($FFMPEG_SIZE)"

# ── SSH connectivity ────────────────────────────────────────────────────
info "Checking device connectivity..."
# SSH will prompt for a password if key authentication is not configured
if ! ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
        -o BatchMode=no -q "${DEVICE_USER}@${DEVICE_IP}" exit 2>/dev/null; then
    error "Cannot connect to ${DEVICE_USER}@${DEVICE_IP}

Check:
  1. Device is powered on and reachable
  2. IP/hostname is correct
  3. SSH is running on device"
fi
success "Device reachable: ${DEVICE_USER}@${DEVICE_IP}"

AVAIL_MB=$(ssh "${DEVICE_USER}@${DEVICE_IP}" \
    "df -m ${INSTALL_DIR} 2>/dev/null || df -m /" | awk 'NR==2{print $4}')
success "Available disk space: ${AVAIL_MB} MB"
if [ "${AVAIL_MB:-0}" -lt 30 ]; then
    error "Insufficient disk space (${AVAIL_MB} MB available, 30 MB needed)"
fi

# ── Sync binaries ───────────────────────────────────────────────────────
info "Syncing binaries..."
if command -v rsync >/dev/null 2>&1; then
    rsync -avz --progress \
        --exclude='*.a' \
        --exclude='pkgconfig/' \
        "$INSTALL_SRC/bin/" \
        "${DEVICE_USER}@${DEVICE_IP}:${INSTALL_DIR}/bin/"
else
    ssh "${DEVICE_USER}@${DEVICE_IP}" "mkdir -p ${INSTALL_DIR}/bin"
    scp "$INSTALL_SRC/bin/ffmpeg" "$INSTALL_SRC/bin/ffprobe" \
        "${DEVICE_USER}@${DEVICE_IP}:${INSTALL_DIR}/bin/"
fi

if [ -f "$REPO_ROOT/scripts/test-on-device.sh" ]; then
    if command -v rsync >/dev/null 2>&1; then
        rsync -avz "$REPO_ROOT/scripts/test-on-device.sh" \
            "${DEVICE_USER}@${DEVICE_IP}:${INSTALL_DIR}/bin/ffmpeg-test.sh"
    else
        scp "$REPO_ROOT/scripts/test-on-device.sh" \
            "${DEVICE_USER}@${DEVICE_IP}:${INSTALL_DIR}/bin/ffmpeg-test.sh"
    fi
fi

# ── Post-install ────────────────────────────────────────────────────────
info "Running post-install on device..."
ssh "${DEVICE_USER}@${DEVICE_IP}" bash << SSHEOF
set -e
chmod +x ${INSTALL_DIR}/bin/ffmpeg ${INSTALL_DIR}/bin/ffprobe 2>/dev/null || true
[ -f "${INSTALL_DIR}/bin/ffmpeg-test.sh" ] && chmod +x ${INSTALL_DIR}/bin/ffmpeg-test.sh || true

if ! echo "\$PATH" | grep -q "${INSTALL_DIR}/bin"; then
    printf 'export PATH="${INSTALL_DIR}/bin:\$PATH"\n' > /etc/profile.d/ffmpeg.sh
    chmod +x /etc/profile.d/ffmpeg.sh
    echo "  Added ${INSTALL_DIR}/bin to PATH"
fi

echo "=== FFmpeg Version ==="
${INSTALL_DIR}/bin/ffmpeg -version 2>&1 | head -5 \
    || { echo "ERROR: ffmpeg failed — check library dependencies"; exit 1; }

echo "=== Hardware Codec Support ==="
echo "MPP Decoders:"
${INSTALL_DIR}/bin/ffmpeg -hide_banner -decoders 2>/dev/null | grep _rkmpp || echo "  none"
echo "MPP Encoders:"
${INSTALL_DIR}/bin/ffmpeg -hide_banner -encoders 2>/dev/null | grep _rkmpp || echo "  none"
echo "RGA Filters:"
${INSTALL_DIR}/bin/ffmpeg -hide_banner -filters 2>/dev/null | grep rkrga || echo "  none"

echo "=== Device Nodes ==="
ls -la /dev/mpp_service /dev/rga 2>/dev/null || echo "  WARNING: /dev/mpp_service or /dev/rga not found"
SSHEOF

printf "\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
success "Deployment complete!"
printf "\nOn the device:\n"
printf "${YELLOW}  ${INSTALL_DIR}/bin/ffmpeg -version${NC}\n"
printf "${YELLOW}  ${INSTALL_DIR}/bin/ffmpeg-test.sh${NC}\n"
printf "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n"
