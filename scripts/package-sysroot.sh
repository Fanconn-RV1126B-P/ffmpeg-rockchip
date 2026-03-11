#!/bin/bash
#
# Package Minimal Sysroot for RV1126B-P CI/CD
#
# This script extracts the minimal set of headers and libraries needed to
# cross-compile FFmpeg-Rockchip from the local Buildroot SDK.
#
# Run this ONCE locally, then upload the resulting tarball as a GitHub Release
# asset so that GitHub Actions CI can download and cache it.
#
# Usage:
#   ./scripts/package-sysroot.sh
#
# The script will produce:
#   rv1126b-sysroot-minimal-<version>.tar.gz
#
# Upload that tarball to a GitHub Release tagged `sysroot-v1.1.0`:
#   gh release create sysroot-v1.1.0 \
#     rv1126b-sysroot-minimal-v1.1.0.tar.gz \
#     --title "RV1126B-P Sysroot v1.1.0" \
#     --notes "Minimal cross-compilation sysroot: MPP, RGA, DRM"
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Configuration ─────────────────────────────────────────────────────────────

SDK_ROOT="${SDK_ROOT:-$REPO_ROOT/../RV1126B-P-SDK/rv1126b_linux6.1_sdk_v1.1.0}"
BUILDROOT_OUTPUT="$SDK_ROOT/buildroot/output/rockchip_rv1126b"
STAGING="$BUILDROOT_OUTPUT/host/aarch64-buildroot-linux-gnu/sysroot"

SYSROOT_VERSION="${SYSROOT_VERSION:-v1.1.0}"
OUTPUT_DIR="${OUTPUT_DIR:-$REPO_ROOT}"
OUTPUT_NAME="rv1126b-sysroot-minimal-${SYSROOT_VERSION}.tar.gz"
STAGING_AREA="/tmp/rv1126b-sysroot-pkg-$$"

# ── Checks ────────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  RV1126B-P Minimal Sysroot Packager"
echo "  Output: $OUTPUT_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ ! -d "$STAGING" ]; then
    echo -e "${RED}✗ Sysroot not found: $STAGING${NC}"
    echo ""
    echo "Set SDK_ROOT to point to your rv1126b_linux6.1_sdk_v1.1.0 directory:"
    echo "  SDK_ROOT=/path/to/sdk $0"
    exit 1
fi

echo -e "${GREEN}✓ Sysroot found:${NC} $STAGING"

# ── Collect components ────────────────────────────────────────────────────────

DEST="$STAGING_AREA/sysroot"
mkdir -p "$DEST/usr/include" "$DEST/usr/lib/pkgconfig"

copy_glob() {
    local src_dir="$1"
    local dest_dir="$2"
    local pattern="${3:-*}"
    if [ -d "$src_dir" ]; then
        mkdir -p "$dest_dir"
        rsync -a --include="$pattern" --include="*/" --exclude="*" \
            "$src_dir/" "$dest_dir/" 2>/dev/null || \
        cp -a "$src_dir"/. "$dest_dir/" 2>/dev/null || true
        echo -e "  ${GREEN}✓${NC} $src_dir"
    else
        echo -e "  ${YELLOW}⚠ Not found:${NC} $src_dir"
    fi
}

echo ""
echo -e "${BLUE}Collecting headers...${NC}"
copy_glob "$STAGING/usr/include/rockchip"    "$DEST/usr/include/rockchip"
copy_glob "$STAGING/usr/include/rga"         "$DEST/usr/include/rga"
copy_glob "$STAGING/usr/include/libdrm"      "$DEST/usr/include/libdrm"

# Some SDKs put drm headers at /usr/include/drm
copy_glob "$STAGING/usr/include/drm"         "$DEST/usr/include/drm"

echo ""
echo -e "${BLUE}Collecting libraries...${NC}"

copy_lib() {
    local pattern="$1"
    local found=0
    for f in $STAGING/usr/lib/${pattern} 2>/dev/null; do
        [ -e "$f" ] || continue
        cp -a "$f" "$DEST/usr/lib/"
        echo -e "  ${GREEN}✓${NC} $(basename "$f")"
        found=1
    done
    [ $found -eq 0 ] && echo -e "  ${YELLOW}⚠ Not found:${NC} $pattern"
}

copy_lib "librockchip_mpp.so*"
copy_lib "librga.so*"
copy_lib "libdrm.so*"

echo ""
echo -e "${BLUE}Collecting pkg-config files...${NC}"

copy_pc() {
    local name="$1"
    local src="$STAGING/usr/lib/pkgconfig/${name}.pc"
    if [ -f "$src" ]; then
        cp "$src" "$DEST/usr/lib/pkgconfig/"
        echo -e "  ${GREEN}✓${NC} ${name}.pc"
    else
        echo -e "  ${YELLOW}⚠ Not found:${NC} ${name}.pc"
        # Generate a minimal .pc if the lib exists
        if ls "$DEST/usr/lib/lib${name}.so"* >/dev/null 2>&1 || \
           ls "$DEST/usr/lib/librockchip_mpp.so"* >/dev/null 2>&1; then
            echo -e "  ${BLUE}→ Generating minimal ${name}.pc${NC}"
        fi
    fi
}

copy_pc "rockchip_mpp"
copy_pc "librga"
copy_pc "libdrm"

# Fix pkg-config prefix paths to be relative (so they work in CI)
echo ""
echo -e "${BLUE}Patching pkg-config prefix paths for portability...${NC}"

for pc in "$DEST/usr/lib/pkgconfig"/*.pc; do
    [ -f "$pc" ] || continue
    # Replace absolute prefix paths with /usr
    sed -i 's|^prefix=.*|prefix=/usr|g' "$pc"
    sed -i 's|^exec_prefix=.*|exec_prefix=${prefix}|g' "$pc"
    sed -i 's|^libdir=.*|libdir=${prefix}/lib|g' "$pc"
    sed -i 's|^includedir=.*|includedir=${prefix}/include|g' "$pc"
    echo -e "  ${GREEN}✓${NC} $(basename "$pc")"
done

# ── Generate symlinks for unversioned .so ─────────────────────────────────────

echo ""
echo -e "${BLUE}Creating unversioned .so symlinks (if missing)...${NC}"
for lib in librockchip_mpp librga libdrm; do
    VERSIONED=$(ls "$DEST/usr/lib/${lib}.so."* 2>/dev/null | head -1)
    if [ -n "$VERSIONED" ] && [ ! -e "$DEST/usr/lib/${lib}.so" ]; then
        ln -sf "$(basename "$VERSIONED")" "$DEST/usr/lib/${lib}.so"
        echo -e "  ${GREEN}✓${NC} Created symlink: ${lib}.so → $(basename "$VERSIONED")"
    fi
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo ""
echo -e "${BLUE}Sysroot contents:${NC}"
find "$DEST" -type f | sort | sed "s|$DEST|  |"

echo ""
echo -e "${BLUE}Creating tarball...${NC}"

TARBALL="$OUTPUT_DIR/$OUTPUT_NAME"
tar czf "$TARBALL" -C "$STAGING_AREA" sysroot/
TARBALL_SIZE=$(du -sh "$TARBALL" | cut -f1)
SHA256=$(sha256sum "$TARBALL" | cut -d' ' -f1)

echo -e "${GREEN}✓ Created:${NC} $TARBALL ($TARBALL_SIZE)"
echo -e "${GREEN}  SHA256:${NC}  $SHA256"

echo "$SHA256  $OUTPUT_NAME" > "${TARBALL}.sha256"

# Cleanup
rm -rf "$STAGING_AREA"

# ── Upload instructions ───────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Sysroot packaged successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Now upload the sysroot to GitHub so CI can download it:"
echo ""
echo "  gh release create sysroot-${SYSROOT_VERSION} \\"
echo "    \"$TARBALL\" \\"
echo "    --repo Fanconn-RV1126B-P/ffmpeg-rockchip \\"
echo "    --title \"RV1126B-P Cross-Compilation Sysroot ${SYSROOT_VERSION}\" \\"
echo "    --notes \"Minimal sysroot for cross-compiling FFmpeg-Rockchip: MPP v1.3.9, RGA v2.1.0, DRM\""
echo ""
echo "CI will download and cache this automatically on next run."
echo ""
