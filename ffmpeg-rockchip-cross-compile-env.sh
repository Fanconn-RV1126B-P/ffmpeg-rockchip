#!/bin/bash
#
# FFmpeg-Rockchip Cross-Compilation Environment Setup
# For RV1126B-P with MPP and RGA hardware acceleration
#
# This script sets up the cross-compilation environment for building
# FFmpeg-Rockchip with Rockchip MPP (Media Process Platform) and RGA
# (Raster Graphics Acceleration) support.
#
# Expected directory structure:
#   parent/
#   ├── ffmpeg-rockchip/           (this repository)
#   └── RV1126B-P-SDK/
#       └── rv1126b_linux6.1_sdk_v1.1.0/
#
# Usage:
#   source ./ffmpeg-rockchip-cross-compile-env.sh
#

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FFmpeg-Rockchip Cross-Compilation Environment Setup"
echo "  Target: RV1126B-P (ARM64/aarch64)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Detect SDK location (assume it's a sibling directory)
SDK_ROOT="$SCRIPT_DIR/../RV1126B-P-SDK/rv1126b_linux6.1_sdk_v1.1.0"

# Check if SDK exists
if [ ! -d "$SDK_ROOT" ]; then
    echo -e "${RED}✗ Error: SDK not found at expected location!${NC}"
    echo ""
    echo "Expected location: $SDK_ROOT"
    echo ""
    echo "Please ensure your directory structure is:"
    echo "  parent/"
    echo "  ├── ffmpeg-rockchip/           (this repository)"
    echo "  └── RV1126B-P-SDK/"
    echo "      └── rv1126b_linux6.1_sdk_v1.1.0/"
    echo ""
    echo "If your SDK is in a different location, you can override with:"
    echo "  export SDK_ROOT=/path/to/rv1126b_linux6.1_sdk_v1.1.0"
    echo "  source $0"
    return 1 2>/dev/null || exit 1
fi

# Convert to absolute path
SDK_ROOT="$(cd "$SDK_ROOT" && pwd)"

# Buildroot output directory
BUILDROOT_OUTPUT="$SDK_ROOT/buildroot/output/rockchip_rv1126b"

# Check if buildroot output exists
if [ ! -d "$BUILDROOT_OUTPUT" ]; then
    echo -e "${RED}✗ Error: Buildroot output not found!${NC}"
    echo ""
    echo "Expected: $BUILDROOT_OUTPUT"
    echo ""
    echo "You need to build the SDK first:"
    echo "  cd $SDK_ROOT"
    echo "  ./build.sh"
    echo ""
    return 1 2>/dev/null || exit 1
fi

# Staging directory (sysroot) for cross-compilation
export STAGING="$BUILDROOT_OUTPUT/host/aarch64-buildroot-linux-gnu/sysroot"

# Check if sysroot exists
if [ ! -d "$STAGING" ]; then
    echo -e "${RED}✗ Error: Sysroot not found!${NC}"
    echo ""
    echo "Expected: $STAGING"
    echo ""
    echo "The SDK buildroot output seems incomplete. Please rebuild:"
    echo "  cd $SDK_ROOT"
    echo "  ./build.sh"
    echo ""
    return 1 2>/dev/null || exit 1
fi

# Toolchain directory
export TOOLCHAIN="$BUILDROOT_OUTPUT/host"

# Add toolchain to PATH
export PATH="$TOOLCHAIN/bin:$PATH"

# Cross-compiler prefix
export CROSS_PREFIX="aarch64-buildroot-linux-gnu-"

# pkg-config setup for finding libraries
export PKG_CONFIG_PATH="$STAGING/usr/lib/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$STAGING"
export PKG_CONFIG_LIBDIR="$STAGING/usr/lib/pkgconfig"

# Explicit pkg-config binary path (needed for FFmpeg configure)
export PKG_CONFIG="$TOOLCHAIN/bin/pkg-config"

# FFmpeg source directory
export FFMPEG_SRC="$SCRIPT_DIR"

# Installation prefix (where to install FFmpeg)
# Default: install to a subdirectory of the ffmpeg source
export FFMPEG_PREFIX="${FFMPEG_PREFIX:-$SCRIPT_DIR/install}"

# Export SDK_ROOT for reference
export SDK_ROOT

echo -e "${GREEN}✓ Environment Paths:${NC}"
echo "  SDK Root:   $SDK_ROOT"
echo "  Toolchain:  $TOOLCHAIN/bin"
echo "  Sysroot:    $STAGING"
echo "  FFmpeg Src: $FFMPEG_SRC"
echo "  Install To: $FFMPEG_PREFIX"
echo ""

# Verify toolchain
echo "Checking toolchain..."
if ! command -v ${CROSS_PREFIX}gcc &> /dev/null; then
    echo -e "${RED}✗ Cross-compiler not found in PATH${NC}"
    echo ""
    echo "Toolchain should be at: $TOOLCHAIN/bin"
    return 1 2>/dev/null || exit 1
fi

GCC_VERSION=$(${CROSS_PREFIX}gcc --version | head -n1)
echo -e "${GREEN}✓ Toolchain:${NC} $GCC_VERSION"

# Verify MPP
echo ""
echo "Checking MPP (Media Process Platform)..."
if pkg-config --exists rockchip_mpp 2>/dev/null; then
    MPP_VERSION=$(pkg-config --modversion rockchip_mpp)
    echo -e "${GREEN}✓ MPP found:${NC} v$MPP_VERSION"
    
    # Check for MPP headers
    if [ -f "$STAGING/usr/include/rockchip/rk_mpi.h" ]; then
        echo -e "${GREEN}✓ MPP headers:${NC} $STAGING/usr/include/rockchip/"
    else
        echo -e "${YELLOW}⚠ MPP headers not found${NC}"
    fi
    
    # Check for MPP library
    if [ -f "$STAGING/usr/lib/librockchip_mpp.so" ]; then
        MPP_SIZE=$(du -h "$STAGING/usr/lib/librockchip_mpp.so" | cut -f1)
        echo -e "${GREEN}✓ MPP library:${NC} $STAGING/usr/lib/librockchip_mpp.so ($MPP_SIZE)"
    else
        echo -e "${YELLOW}⚠ MPP library not found${NC}"
    fi
else
    echo -e "${RED}✗ MPP not found via pkg-config${NC}"
    echo ""
    echo "MPP is required for hardware video encoding/decoding."
    echo "Please ensure the SDK was built correctly."
    return 1 2>/dev/null || exit 1
fi

# Verify RGA
echo ""
echo "Checking RGA (Raster Graphics Acceleration)..."
if pkg-config --exists librga 2>/dev/null; then
    RGA_VERSION=$(pkg-config --modversion librga)
    echo -e "${GREEN}✓ RGA found:${NC} v$RGA_VERSION"
    
    # Check for RGA headers
    if [ -d "$STAGING/usr/include/rga" ]; then
        echo -e "${GREEN}✓ RGA headers:${NC} $STAGING/usr/include/rga/"
    else
        echo -e "${YELLOW}⚠ RGA headers not found${NC}"
    fi
    
    # Check for RGA library
    if [ -f "$STAGING/usr/lib/librga.so" ]; then
        RGA_SIZE=$(du -h "$STAGING/usr/lib/librga.so" | cut -f1)
        echo -e "${GREEN}✓ RGA library:${NC} $STAGING/usr/lib/librga.so ($RGA_SIZE)"
    else
        echo -e "${YELLOW}⚠ RGA library not found${NC}"
    fi
else
    echo -e "${RED}✗ RGA not found via pkg-config${NC}"
    echo ""
    echo "RGA is required for hardware 2D graphics acceleration."
    echo "Please ensure the SDK was built correctly."
    return 1 2>/dev/null || exit 1
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Environment configured successfully!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "You can now configure and build FFmpeg:"
echo ""
echo "  # Minimal build (hardware codecs only, ~10-15 MB)"
echo "  ./configure \\"
echo "    --prefix=\$FFMPEG_PREFIX \\"
echo "    --enable-cross-compile \\"
echo "    --cross-prefix=\${CROSS_PREFIX} \\"
echo "    --arch=aarch64 \\"
echo "    --target-os=linux \\"
echo "    --sysroot=\$STAGING \\"
echo "    --pkg-config=\$PKG_CONFIG \\"
echo "    --enable-gpl \\"
echo "    --enable-version3 \\"
echo "    --enable-libdrm \\"
echo "    --enable-rkmpp \\"
echo "    --enable-rkrga \\"
echo "    --disable-static \\"
echo "    --enable-shared"
echo ""
echo "  # Build"
echo "  make -j\$(nproc)"
echo ""
echo "  # Install"
echo "  make install"
echo ""
echo "For more configuration options, see:"
echo "  https://github.com/Fanconn-RV1126B-P/RV1126B-P-Docs"
echo ""

# Export a marker so we know the environment is loaded
export FFMPEG_ROCKCHIP_ENV_LOADED=1
