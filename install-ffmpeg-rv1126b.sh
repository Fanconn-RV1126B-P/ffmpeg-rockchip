#!/bin/sh
#
# install-ffmpeg-rv1126b.sh
# One-line installer for FFmpeg-Rockchip on RV1126B-P
#
# Usage (run on the device):
#   wget -qO- https://github.com/Fanconn-RV1126B-P/ffmpeg-rockchip/releases/latest/download/install-ffmpeg-rv1126b.sh | sh
#   — or —
#   curl -fsSL https://github.com/Fanconn-RV1126B-P/ffmpeg-rockchip/releases/latest/download/install-ffmpeg-rv1126b.sh | sh

set -e

REPO="Fanconn-RV1126B-P/ffmpeg-rockchip"
INSTALL_PREFIX="/usr/local"
TMP_DIR="/tmp/ffmpeg-rv1126b-install"

# ── Colours (fall back silently if terminal doesn't support them) ─────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { printf "${BLUE}[+]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error()   { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

# ── Sanity checks ─────────────────────────────────────────────────────────────
command -v wget  >/dev/null 2>&1 || error "wget is required but not found"
command -v tar   >/dev/null 2>&1 || error "tar is required but not found"

ARCH=$(uname -m)
[ "$ARCH" = "aarch64" ] || warn "This build targets aarch64; detected $ARCH — proceed at your own risk"

# ── Discover latest release asset ─────────────────────────────────────────────
info "Discovering latest release from github.com/$REPO ..."

LATEST_URL="https://github.com/${REPO}/releases/latest"
# Follow redirect to find the resolved tag name
TAG=$(wget -qSO /dev/null "$LATEST_URL" 2>&1 | grep -i 'location:' | sed 's|.*/tag/\(.*\)|\1|' | tr -d '[:space:]')

if [ -z "$TAG" ]; then
    # Fallback: scrape the redirect target via wget --server-response
    TAG=$(wget -qS --spider "$LATEST_URL" 2>&1 | awk '/Location:/{print $2}' | sed 's|.*/tag/||' | tr -d '[:space:]')
fi

[ -n "$TAG" ] || error "Could not determine latest release tag from $LATEST_URL"
info "Latest release tag: $TAG"

# Build asset download URL (the .tar.gz; file name contains date + commit hash)
ASSET_BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

# Get the filename from the release page HTML (look for the tarball pattern)
ASSET_NAME=$(wget -qO- "https://github.com/${REPO}/releases/expanded_assets/${TAG}" 2>/dev/null \
    | grep -oE "ffmpeg-rv1126b-[0-9]+-[a-f0-9]+\.tar\.gz" | head -1)

if [ -z "$ASSET_NAME" ]; then
    # Fallback: list release assets via GitHub redirect JSON
    ASSET_NAME=$(wget -qO- "${ASSET_BASE_URL}/" 2>/dev/null \
        | grep -oE "ffmpeg-rv1126b-[0-9]+-[a-f0-9]+\.tar\.gz" | head -1)
fi

[ -n "$ASSET_NAME" ] || error "Could not find release asset .tar.gz for tag $TAG"
info "Asset: $ASSET_NAME"

# ── Download ──────────────────────────────────────────────────────────────────
rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"
TARBALL="$TMP_DIR/$ASSET_NAME"

info "Downloading $ASSET_NAME ..."
wget -q --show-progress -O "$TARBALL" "${ASSET_BASE_URL}/${ASSET_NAME}" \
    || wget -O "$TARBALL" "${ASSET_BASE_URL}/${ASSET_NAME}"

# Verify SHA256 if checksum file is present
CHECKSUM_URL="${ASSET_BASE_URL}/${ASSET_NAME}.sha256"
if wget -qO "$TARBALL.sha256" "$CHECKSUM_URL" 2>/dev/null; then
    info "Verifying checksum ..."
    EXPECTED=$(awk '{print $1}' "$TARBALL.sha256")
    ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        success "Checksum OK ($ACTUAL)"
    else
        error "Checksum mismatch!\n  expected: $EXPECTED\n  actual:   $ACTUAL"
    fi
else
    warn "No checksum file found — skipping verification"
fi

# ── Install ───────────────────────────────────────────────────────────────────
info "Extracting to $INSTALL_PREFIX ..."
tar xzf "$TARBALL" -C "$INSTALL_PREFIX"

# The tarball puts binaries in bin/; copy just ffmpeg and ffprobe
for BIN in ffmpeg ffprobe; do
    if [ -f "$INSTALL_PREFIX/bin/$BIN" ]; then
        chmod +x "$INSTALL_PREFIX/bin/$BIN"
        success "Installed $INSTALL_PREFIX/bin/$BIN"
    else
        warn "$BIN not found in $INSTALL_PREFIX/bin/ after extraction"
    fi
done

# ── Verification ──────────────────────────────────────────────────────────────
printf "\n"
info "Verifying installation ..."
FFMPEG_BIN="$INSTALL_PREFIX/bin/ffmpeg"

if [ ! -f "$FFMPEG_BIN" ]; then
    error "ffmpeg binary not found at $FFMPEG_BIN after install"
fi

$FFMPEG_BIN -version 2>&1 | head -1
success "ffmpeg installed successfully"

printf "\n"
info "Checking for Rockchip MPP hardware codecs ..."
MPP=$($FFMPEG_BIN -hide_banner -codecs 2>&1 | grep rkmpp | wc -l)
if [ "$MPP" -gt 0 ]; then
    success "Found $MPP RKMPP codec(s) — hardware acceleration is available"
else
    warn "No RKMPP codecs found; check that /dev/mpp_service exists and permissions are correct"
fi

# ── Clean up ──────────────────────────────────────────────────────────────────
rm -rf "$TMP_DIR"

# ── Next steps ────────────────────────────────────────────────────────────────
printf "\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${GREEN}  FFmpeg-Rockchip installed successfully!${NC}\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "\n"
printf "  Verify hardware codecs:\n"
printf "${YELLOW}    %s -codecs | grep rkmpp${NC}\n" "$FFMPEG_BIN"
printf "\n"
printf "  Run full hardware test suite (decode / encode / transcode):\n"
printf "${YELLOW}    bash /usr/local/test-on-device.sh${NC}\n"
printf "\n"
printf "  Quick hardware encode test:\n"
printf "${YELLOW}    %s -f lavfi -i testsrc=duration=5:size=1920x1080 -c:v h264_rkmpp -b:v 4M /tmp/test-hw.mp4${NC}\n" "$FFMPEG_BIN"
printf "\n"
