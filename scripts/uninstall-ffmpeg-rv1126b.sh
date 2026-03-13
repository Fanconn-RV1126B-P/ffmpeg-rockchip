#!/bin/sh
#
# uninstall-ffmpeg-rv1126b.sh
# Remove FFmpeg-Rockchip from an RV1126B-P device
#
# Run from host PC to uninstall remotely:
#   sh uninstall-ffmpeg-rv1126b.sh
#   sh uninstall-ffmpeg-rv1126b.sh <DEVICE_IP>
#
# Run directly on the device (aarch64):
#   sh uninstall-ffmpeg-rv1126b.sh
#
# Environment variables:
#   DEVICE_IP    device IP or hostname
#   DEVICE_USER  SSH user (default: root)

set -e

INSTALL_PREFIX="/usr/local"
DEVICE_IP="${1:-${DEVICE_IP:-}}"
DEVICE_USER="${DEVICE_USER:-root}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { printf "${BLUE}[+]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error()   { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }

ARCH=$(uname -m)

if [ -z "$DEVICE_IP" ] && [ "$ARCH" != "aarch64" ]; then
    printf "\n${BLUE}No device IP supplied.${NC}\n"
    printf "Running on ${ARCH} — a device IP is needed.\n\n"
    printf "${YELLOW}Enter device IP address or hostname: ${NC}"
    read -r DEVICE_IP
    [ -n "$DEVICE_IP" ] || error "Device IP is required"
fi

printf "\n"
printf "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${RED}  FFmpeg-Rockchip Uninstaller${NC}\n"
printf "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
[ -n "$DEVICE_IP" ] && printf "  Target  : ${DEVICE_USER}@${DEVICE_IP}\n" \
                     || printf "  Target  : localhost\n"
printf "  Path    : ${INSTALL_PREFIX}/ffmpeg-rv1126b\n\n"

# The actual removal commands (shared between local and remote)
REMOVE_SCRIPT='
set -e
INSTALL_PREFIX="'"${INSTALL_PREFIX}"'"
FFMPEG_DIR="${INSTALL_PREFIX}/ffmpeg-rv1126b"

removed=0

# Remove main install directory
if [ -d "$FFMPEG_DIR" ]; then
    rm -rf "$FFMPEG_DIR"
    echo "[✓] Removed $FFMPEG_DIR"
    removed=1
else
    echo "[!] Not found: $FFMPEG_DIR"
fi

# Remove symlinks in /usr/local/bin that point into ffmpeg-rv1126b
for BIN in ffmpeg ffprobe; do
    LINK="${INSTALL_PREFIX}/bin/$BIN"
    if [ -L "$LINK" ]; then
        TARGET=$(readlink "$LINK")
        case "$TARGET" in
            *ffmpeg-rv1126b*|*ffmpeg-rv1126b*)
                rm -f "$LINK"
                echo "[✓] Removed symlink $LINK"
                removed=1
                ;;
            *)
                echo "[!] Skipping $LINK — points to $TARGET (not our install)"
                ;;
        esac
    fi
done

# Remove PATH profile.d entry if we created it
if [ -f /etc/profile.d/ffmpeg-rv1126b.sh ]; then
    rm -f /etc/profile.d/ffmpeg-rv1126b.sh
    echo "[✓] Removed /etc/profile.d/ffmpeg-rv1126b.sh"
    removed=1
fi

# Remove tmp install dir if present
rm -rf /tmp/ffmpeg-rv1126b-install 2>/dev/null || true

if [ "$removed" -eq 1 ]; then
    echo ""
    echo "[✓] Uninstall complete"
else
    echo ""
    echo "[!] Nothing to remove — FFmpeg-Rockchip does not appear to be installed"
fi
'

if [ -n "$DEVICE_IP" ]; then
    REMOTE="${DEVICE_USER}@${DEVICE_IP}"
    info "Connecting to ${REMOTE} ..."
    ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
        -o BatchMode=no "$REMOTE" "exit" \
        || error "Cannot connect to ${REMOTE}"
    ssh "$REMOTE" sh -c "$REMOVE_SCRIPT"
    success "Remote uninstall complete on ${REMOTE}"
else
    [ "$ARCH" = "aarch64" ] || error "Running on $ARCH — supply a device IP or run on device"
    sh -c "$REMOVE_SCRIPT"
fi
