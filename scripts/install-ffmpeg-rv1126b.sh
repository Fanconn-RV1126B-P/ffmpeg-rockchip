#!/bin/sh
#
# install-ffmpeg-rv1126b.sh
# Installer for FFmpeg-Rockchip on RV1126B-P
#
# Run from host PC to install remotely (recommended):
#   sh install-ffmpeg-rv1126b.sh
#   sh install-ffmpeg-rv1126b.sh <DEVICE_IP>
#   sh install-ffmpeg-rv1126b.sh <DEVICE_IP> rkmpp-sw
#
# Run directly on the device (aarch64):
#   sh install-ffmpeg-rv1126b.sh
#
# Environment variables (override prompts):
#   DEVICE_IP      device IP or hostname
#   DEVICE_USER    SSH user (default: root)
#   FFMPEG_PROFILE rkmpp | rkmpp-sw

set -e

REPO="Fanconn-RV1126B-P/ffmpeg-rockchip"
INSTALL_PREFIX="/usr/local"
TMP_DIR="/tmp/ffmpeg-rv1126b-install"

DEVICE_IP="${1:-${DEVICE_IP:-}}"
PROFILE="${2:-${FFMPEG_PROFILE:-}}"
DEVICE_USER="${DEVICE_USER:-root}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { printf "${BLUE}[+]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error()   { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ask_device_ip() {
    if [ -z "$DEVICE_IP" ]; then
        printf "${YELLOW}Enter device IP address or hostname: ${NC}"
        read -r DEVICE_IP
        [ -n "$DEVICE_IP" ] || error "Device IP is required"
    fi
}

ask_profile() {
    if [ -z "$PROFILE" ]; then
        printf "\n${BLUE}Available profiles:${NC}\n"
        printf "  1) rkmpp     Hardware codecs only (MPP h264/hevc/vp8/vp9 + RGA)\n"
        printf "  2) rkmpp-sw  Hardware + software codecs (libx264/x265/vpx/aom)\n"
        printf "\n${YELLOW}Select profile [1/2, default: 1]: ${NC}"
        read -r _choice
        case "$_choice" in
            2|rkmpp-sw|rkmpp_software) PROFILE="rkmpp-sw" ;;
            *)                          PROFILE="rkmpp" ;;
        esac
    fi
    [ "$PROFILE" = "rkmpp_software" ] && PROFILE="rkmpp-sw"
}

fetch_to_file() {
    if have_cmd curl; then curl -fsSL "$1" -o "$2"; return; fi
    if have_cmd wget; then wget -q -O "$2" "$1"; return; fi
    error "curl or wget is required but not found"
}

fetch_to_stdout() {
    if have_cmd curl; then curl -fsSL "$1"; return; fi
    if have_cmd wget; then wget -qO- "$1"; return; fi
    error "curl or wget is required but not found"
}

have_cmd tar       || error "tar is required but not found"
have_cmd sha256sum || error "sha256sum is required but not found"

ARCH=$(uname -m)

if [ -z "$DEVICE_IP" ] && [ "$ARCH" != "aarch64" ]; then
    printf "\n${BLUE}No device IP supplied.${NC}\n"
    printf "Running on ${ARCH} — a device IP is needed for remote install.\n\n"
    ask_device_ip
fi

ask_profile

printf "\n"
info "Repository : $REPO"
info "Profile    : $PROFILE"
[ -n "$DEVICE_IP" ] && info "Device     : ${DEVICE_USER}@${DEVICE_IP}" \
                    || info "Device     : localhost (aarch64)"

info "Discovering latest release from github.com/$REPO ..."

LATEST_URL="https://github.com/${REPO}/releases/latest"
if have_cmd curl; then
    TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$LATEST_URL" \
          | sed 's|.*/tag/||' | tr -d '[:space:]')
else
    TAG=$(wget -qSO /dev/null "$LATEST_URL" 2>&1 \
          | awk '/[Ll]ocation:/{print $2}' | sed 's|.*/tag/||' | tr -d '[:space:]')
fi
[ -n "$TAG" ] || error "Could not determine latest release tag from $LATEST_URL"
info "Latest tag: $TAG"

ASSET_BASE_URL="https://github.com/${REPO}/releases/download/${TAG}"

# Regex: rkmpp-sw matches rkmpp-sw-* and rkmpp-software-* (start with 's')
#        rkmpp    matches rkmpp-{digit}-* (version digit, not letter)
if [ "$PROFILE" = "rkmpp-sw" ]; then
    ASSET_GREP='ffmpeg-rv1126b-rkmpp-s[^"[:space:]]*\.tar\.gz'
else
    ASSET_GREP='ffmpeg-rv1126b-rkmpp-[0-9][^"[:space:]]*\.tar\.gz'
fi

ASSET_NAME=$(fetch_to_stdout \
    "https://github.com/${REPO}/releases/expanded_assets/${TAG}" 2>/dev/null \
    | grep -oE "$ASSET_GREP" | grep -v '\.sha256' | head -1)

if [ -z "$ASSET_NAME" ]; then
    ASSET_NAME=$(fetch_to_stdout \
        "https://github.com/${REPO}/releases/tag/${TAG}" 2>/dev/null \
        | grep -oE "$ASSET_GREP" | grep -v '\.sha256' | head -1)
fi

[ -n "$ASSET_NAME" ] || error "No '$PROFILE' asset found in release $TAG"
info "Asset: $ASSET_NAME"

rm -rf "$TMP_DIR" && mkdir -p "$TMP_DIR"
TARBALL="$TMP_DIR/$ASSET_NAME"

info "Downloading $ASSET_NAME ..."
fetch_to_file "${ASSET_BASE_URL}/${ASSET_NAME}" "$TARBALL" \
    || error "Failed to download ${ASSET_NAME}"

CHECKSUM_URL="${ASSET_BASE_URL}/${ASSET_NAME}.sha256"
if fetch_to_file "$CHECKSUM_URL" "$TARBALL.sha256" 2>/dev/null; then
    info "Verifying checksum ..."
    EXPECTED=$(awk '{print $1}' "$TARBALL.sha256")
    ACTUAL=$(sha256sum "$TARBALL" | awk '{print $1}')
    if [ "$EXPECTED" = "$ACTUAL" ]; then
        success "Checksum OK"
    else
        error "Checksum mismatch\n  expected: $EXPECTED\n  actual:   $ACTUAL"
    fi
else
    warn "No checksum file — skipping verification"
fi

install_local() {
    info "Extracting to $INSTALL_PREFIX ..."
    tar xzf "$TARBALL" -C "$INSTALL_PREFIX"

    for BIN in ffmpeg ffprobe; do
        WRAPPER="$INSTALL_PREFIX/ffmpeg-rv1126b/bin/${BIN}-rv1126b"
        LINK="$INSTALL_PREFIX/bin/$BIN"
        if [ -f "$WRAPPER" ] && [ ! -e "$LINK" ]; then
            mkdir -p "$INSTALL_PREFIX/bin"
            ln -sf "$WRAPPER" "$LINK"
            success "Symlink: $LINK"
        fi
    done

    if [ ! -f /etc/profile.d/ffmpeg-rv1126b.sh ]; then
        printf 'export PATH="$PATH:%s/bin"\n' "$INSTALL_PREFIX" \
            > /etc/profile.d/ffmpeg-rv1126b.sh 2>/dev/null || true
    fi

    _ffmpeg="$INSTALL_PREFIX/bin/ffmpeg"
    [ -x "$_ffmpeg" ] || _ffmpeg="$INSTALL_PREFIX/ffmpeg-rv1126b/bin/ffmpeg-rv1126b"
    "$_ffmpeg" -version 2>&1 | head -1
    success "Installation complete"

    MPP=$("$_ffmpeg" -hide_banner -codecs 2>&1 | grep -c rkmpp || true)
    if [ "${MPP:-0}" -gt 0 ]; then
        success "Found $MPP RKMPP codec(s)"
    else
        warn "No RKMPP codecs found; check /dev/mpp_service"
    fi
}

install_remote() {
    have_cmd ssh || error "ssh is required for remote install"
    have_cmd scp || error "scp is required for remote install"

    REMOTE="${DEVICE_USER}@${DEVICE_IP}"
    info "Connecting to ${REMOTE} ..."

    # SSH will prompt for password if key auth is not configured
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o BatchMode=no "$REMOTE" "exit" \
        || error "Cannot connect to ${REMOTE}"

    ssh "$REMOTE" "mkdir -p '${TMP_DIR}'"
    scp -q "$TARBALL" "$TARBALL.sha256" "$REMOTE:${TMP_DIR}/" 2>/dev/null || \
        scp    "$TARBALL" "$TARBALL.sha256" "$REMOTE:${TMP_DIR}/"

    REMOTE_TARBALL="${TMP_DIR}/${ASSET_NAME}"
    REMOTE_SHA="${REMOTE_TARBALL}.sha256"

    ssh "$REMOTE" sh << EOF
set -e
INSTALL_PREFIX="${INSTALL_PREFIX}"

if [ -f "${REMOTE_SHA}" ]; then
    EXPECTED=\$(awk '{print \$1}' "${REMOTE_SHA}")
    ACTUAL=\$(sha256sum "${REMOTE_TARBALL}" | awk '{print \$1}')
    [ "\$EXPECTED" = "\$ACTUAL" ] || { echo "[X] Checksum mismatch"; exit 1; }
    echo "[+] Checksum OK"
fi

tar xzf "${REMOTE_TARBALL}" -C "\${INSTALL_PREFIX}"

for BIN in ffmpeg ffprobe; do
    WRAPPER="\${INSTALL_PREFIX}/ffmpeg-rv1126b/bin/\${BIN}-rv1126b"
    LINK="\${INSTALL_PREFIX}/bin/\${BIN}"
    if [ -f "\$WRAPPER" ] && [ ! -e "\$LINK" ]; then
        mkdir -p "\${INSTALL_PREFIX}/bin"
        ln -sf "\$WRAPPER" "\$LINK"
        echo "[+] Symlink: \$LINK"
    fi
done

if [ ! -f /etc/profile.d/ffmpeg-rv1126b.sh ]; then
    printf 'export PATH="\$PATH:%s/bin"\n' "\${INSTALL_PREFIX}" \
        > /etc/profile.d/ffmpeg-rv1126b.sh 2>/dev/null || true
fi

_ffmpeg="\${INSTALL_PREFIX}/bin/ffmpeg"
[ -x "\$_ffmpeg" ] || _ffmpeg="\${INSTALL_PREFIX}/ffmpeg-rv1126b/bin/ffmpeg-rv1126b"
"\$_ffmpeg" -version 2>&1 | head -1
echo "remote_install_ok"
EOF

    success "Remote install complete on ${REMOTE}"
}

if [ -n "$DEVICE_IP" ]; then
    install_remote
else
    [ "$ARCH" = "aarch64" ] || error "Running on $ARCH — supply a device IP or run on device"
    install_local
fi

rm -rf "$TMP_DIR"

printf "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${GREEN}  Installed: ffmpeg-rockchip  profile=%s${NC}\n" "$PROFILE"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"
printf "  Verify:     ffmpeg -hide_banner -codecs 2>&1 | grep rkmpp\n"
printf "  Test suite: bash /usr/local/ffmpeg-rv1126b/test-on-device.sh\n"
printf "  Uninstall:  sh scripts/uninstall-ffmpeg-rv1126b.sh\n\n"
