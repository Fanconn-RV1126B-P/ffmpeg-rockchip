#!/bin/sh
#
# install-ffmpeg-rv1126b.sh
# One-line installer for FFmpeg-Rockchip on RV1126B-P
#
# Usage (recommended, run on host PC):
#   curl -fsSL https://github.com/Fanconn-RV1126B-P/ffmpeg-rockchip/releases/latest/download/install-ffmpeg-rv1126b.sh | sh -s -- 192.168.1.95
#
# Optional local mode (run on device directly):
#   curl -fsSL https://github.com/Fanconn-RV1126B-P/ffmpeg-rockchip/releases/latest/download/install-ffmpeg-rv1126b.sh | sh

set -e

REPO="Fanconn-RV1126B-P/ffmpeg-rockchip"
INSTALL_PREFIX="/usr/local"
TMP_DIR="/tmp/ffmpeg-rv1126b-install"
DEVICE_IP="${1:-${DEVICE_IP:-}}"
DEVICE_USER="${DEVICE_USER:-root}"

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

have_cmd() { command -v "$1" >/dev/null 2>&1; }

fetch_to_file() {
    URL="$1"
    OUT="$2"
    if have_cmd curl; then
        curl -fsSL "$URL" -o "$OUT"
        return 0
    fi
    if have_cmd wget; then
        wget -q -O "$OUT" "$URL"
        return 0
    fi
    return 1
}

fetch_to_stdout() {
    URL="$1"
    if have_cmd curl; then
        curl -fsSL "$URL"
        return 0
    fi
    if have_cmd wget; then
        wget -qO- "$URL"
        return 0
    fi
    return 1
}

# ── Sanity checks ─────────────────────────────────────────────────────────────
have_cmd tar || error "tar is required but not found"
have_cmd sha256sum || error "sha256sum is required but not found"
(have_cmd curl || have_cmd wget) || error "curl or wget is required but not found"

ARCH=$(uname -m)

# ── Discover latest release asset ─────────────────────────────────────────────
info "Discovering latest release from github.com/$REPO ..."

LATEST_URL="https://github.com/${REPO}/releases/latest"
if have_cmd curl; then
    TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$LATEST_URL" | sed 's|.*/tag/||' | tr -d '[:space:]')
else
    TAG=$(wget -qSO /dev/null "$LATEST_URL" 2>&1 | awk '/[Ll]ocation:/{print $2}' | sed 's|.*/tag/||' | tr -d '[:space:]')
fi

[ -n "$TAG" ] || error "Could not determine latest release tag from $LATEST_URL"
info "Latest release tag: $TAG"

# Build asset download URL (the .tar.gz; file name contains date + commit hash)
ASSET_BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

# Get the filename from the release page HTML (look for the tarball pattern)
ASSET_NAME=$(fetch_to_stdout "https://github.com/${REPO}/releases/expanded_assets/${TAG}" 2>/dev/null \
    | grep -oE "ffmpeg-rv1126b-[0-9]+-[0-9]{8}-[a-f0-9]+\.tar\.gz" | head -1)

if [ -z "$ASSET_NAME" ]; then
    ASSET_NAME=$(fetch_to_stdout "https://github.com/${REPO}/releases/tag/${TAG}" 2>/dev/null \
        | grep -oE "ffmpeg-rv1126b-[0-9]+-[0-9]{8}-[a-f0-9]+\.tar\.gz" | head -1)
fi

[ -n "$ASSET_NAME" ] || error "Could not find release asset .tar.gz for tag $TAG"
info "Asset: $ASSET_NAME"

# ── Download ──────────────────────────────────────────────────────────────────
rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"
TARBALL="$TMP_DIR/$ASSET_NAME"

info "Downloading $ASSET_NAME ..."
fetch_to_file "${ASSET_BASE_URL}/${ASSET_NAME}" "$TARBALL" \
    || error "Failed to download asset ${ASSET_NAME}"

# Verify SHA256 if checksum file is present
CHECKSUM_URL="${ASSET_BASE_URL}/${ASSET_NAME}.sha256"
if fetch_to_file "$CHECKSUM_URL" "$TARBALL.sha256" 2>/dev/null; then
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

install_local() {
    info "Extracting to $INSTALL_PREFIX ..."
    tar xzf "$TARBALL" -C "$INSTALL_PREFIX"

    if [ -f "$INSTALL_PREFIX/ffmpeg-rv1126b/bin/ffmpeg" ] && [ ! -f "$INSTALL_PREFIX/bin/ffmpeg" ]; then
        mkdir -p "$INSTALL_PREFIX/bin"
        cp -f "$INSTALL_PREFIX/ffmpeg-rv1126b/bin/ffmpeg" "$INSTALL_PREFIX/bin/ffmpeg"
        cp -f "$INSTALL_PREFIX/ffmpeg-rv1126b/bin/ffprobe" "$INSTALL_PREFIX/bin/ffprobe"
    fi

    if [ -f "$INSTALL_PREFIX/ffmpeg-rv1126b/test-on-device.sh" ] && [ ! -f "$INSTALL_PREFIX/test-on-device.sh" ]; then
        cp -f "$INSTALL_PREFIX/ffmpeg-rv1126b/test-on-device.sh" "$INSTALL_PREFIX/test-on-device.sh"
        chmod +x "$INSTALL_PREFIX/test-on-device.sh"
    fi

    for BIN in ffmpeg ffprobe; do
        if [ -f "$INSTALL_PREFIX/bin/$BIN" ]; then
            chmod +x "$INSTALL_PREFIX/bin/$BIN"
            success "Installed $INSTALL_PREFIX/bin/$BIN"
        else
            warn "$BIN not found in $INSTALL_PREFIX/bin/ after extraction"
        fi
    done

    printf "\n"
    info "Verifying installation ..."
    FFMPEG_BIN="$INSTALL_PREFIX/bin/ffmpeg"

    [ -f "$FFMPEG_BIN" ] || error "ffmpeg binary not found at $FFMPEG_BIN after install"
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
}

install_remote() {
    have_cmd ssh || error "ssh is required for host mode"
    have_cmd scp || error "scp is required for host mode"

    REMOTE="${DEVICE_USER}@${DEVICE_IP}"
    info "Installing remotely on ${REMOTE} ..."

    ssh -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new "$REMOTE" "exit" \
        || error "Cannot connect to ${REMOTE}"

    scp -q "$TARBALL" "$TARBALL.sha256" "$REMOTE:${TMP_DIR}/" 2>/dev/null || {
        ssh "$REMOTE" "mkdir -p '${TMP_DIR}'"
        scp -q "$TARBALL" "$TARBALL.sha256" "$REMOTE:${TMP_DIR}/"
    }

    REMOTE_TARBALL="${TMP_DIR}/${ASSET_NAME}"
    REMOTE_SHA="${REMOTE_TARBALL}.sha256"

    ssh "$REMOTE" sh <<EOF
set -e
INSTALL_PREFIX="$INSTALL_PREFIX"
REMOTE_TARBALL="$REMOTE_TARBALL"
REMOTE_SHA="$REMOTE_SHA"

EXPECTED=\$(awk '{print \$1}' "\$REMOTE_SHA")
ACTUAL=\$(sha256sum "\$REMOTE_TARBALL" | awk '{print \$1}')
[ "\$EXPECTED" = "\$ACTUAL" ] || { echo "Checksum mismatch on device"; exit 1; }

tar xzf "\$REMOTE_TARBALL" -C "\$INSTALL_PREFIX"

if [ -f "\$INSTALL_PREFIX/ffmpeg-rv1126b/bin/ffmpeg" ] && [ ! -f "\$INSTALL_PREFIX/bin/ffmpeg" ]; then
  mkdir -p "\$INSTALL_PREFIX/bin"
  cp -f "\$INSTALL_PREFIX/ffmpeg-rv1126b/bin/ffmpeg" "\$INSTALL_PREFIX/bin/ffmpeg"
  cp -f "\$INSTALL_PREFIX/ffmpeg-rv1126b/bin/ffprobe" "\$INSTALL_PREFIX/bin/ffprobe"
fi

if [ -f "\$INSTALL_PREFIX/ffmpeg-rv1126b/test-on-device.sh" ] && [ ! -f "\$INSTALL_PREFIX/test-on-device.sh" ]; then
  cp -f "\$INSTALL_PREFIX/ffmpeg-rv1126b/test-on-device.sh" "\$INSTALL_PREFIX/test-on-device.sh"
  chmod +x "\$INSTALL_PREFIX/test-on-device.sh"
fi

chmod +x "\$INSTALL_PREFIX/bin/ffmpeg" "\$INSTALL_PREFIX/bin/ffprobe" 2>/dev/null || true
"\$INSTALL_PREFIX/bin/ffmpeg" -version 2>&1 | head -1
echo "remote_install_ok"
EOF

    success "Remote install completed on ${REMOTE}"
}

if [ -n "$DEVICE_IP" ]; then
    install_remote
else
    [ "$ARCH" = "aarch64" ] || error "Host mode requires device IP. Usage: sh install-ffmpeg-rv1126b.sh <DEVICE_IP>"
    install_local
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
printf "${YELLOW}    /usr/local/bin/ffmpeg -codecs | grep rkmpp${NC}\n"
printf "\n"
printf "  Run full hardware test suite (decode / encode / transcode):\n"
printf "${YELLOW}    bash /usr/local/test-on-device.sh${NC}\n"
printf "\n"
printf "  Quick hardware encode test:\n"
printf "${YELLOW}    /usr/local/bin/ffmpeg -f lavfi -i testsrc=duration=5:size=1920x1080 -c:v h264_rkmpp -b:v 4M /tmp/test-hw.mp4${NC}\n"
printf "\n"
