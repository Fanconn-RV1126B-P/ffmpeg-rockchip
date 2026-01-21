#!/bin/bash
#
# FFmpeg-Rockchip Build Verification Script
# Verifies cross-compiled FFmpeg without requiring target hardware
#

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  FFmpeg-Rockchip Build Verification"
echo "  Verify cross-compiled build without target hardware"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${FFMPEG_PREFIX:-$SCRIPT_DIR/install}"

if [ ! -d "$INSTALL_DIR" ]; then
    echo -e "${RED}✗ Install directory not found: $INSTALL_DIR${NC}"
    echo "Run 'make install' first!"
    exit 1
fi

echo -e "${BLUE}📁 Installation Directory:${NC} $INSTALL_DIR"
echo ""

# 1. Check binaries exist
echo -e "${BLUE}1. Checking binaries...${NC}"
FFMPEG_BIN="$INSTALL_DIR/bin/ffmpeg"
FFPROBE_BIN="$INSTALL_DIR/bin/ffprobe"

if [ -f "$FFMPEG_BIN" ]; then
    SIZE=$(du -h "$FFMPEG_BIN" | cut -f1)
    echo -e "${GREEN}✓ ffmpeg binary found${NC} ($SIZE)"
else
    echo -e "${RED}✗ ffmpeg binary not found${NC}"
    exit 1
fi

if [ -f "$FFPROBE_BIN" ]; then
    SIZE=$(du -h "$FFPROBE_BIN" | cut -f1)
    echo -e "${GREEN}✓ ffprobe binary found${NC} ($SIZE)"
else
    echo -e "${YELLOW}⚠ ffprobe binary not found${NC}"
fi

echo ""

# 2. Check architecture
echo -e "${BLUE}2. Verifying architecture...${NC}"
ARCH_INFO=$(file "$FFMPEG_BIN")

if echo "$ARCH_INFO" | grep -q "ARM aarch64"; then
    echo -e "${GREEN}✓ Correct architecture: ARM aarch64 (64-bit)${NC}"
    echo "  $ARCH_INFO"
else
    echo -e "${RED}✗ Wrong architecture!${NC}"
    echo "  $ARCH_INFO"
    exit 1
fi

echo ""

# 3. Check library dependencies
echo -e "${BLUE}3. Checking library dependencies...${NC}"

if command -v aarch64-buildroot-linux-gnu-readelf &> /dev/null; then
    READELF="aarch64-buildroot-linux-gnu-readelf"
elif command -v aarch64-linux-gnu-readelf &> /dev/null; then
    READELF="aarch64-linux-gnu-readelf"
else
    echo -e "${YELLOW}⚠ No ARM readelf found, skipping dependency check${NC}"
    READELF=""
fi

if [ -n "$READELF" ]; then
    DEPS=$($READELF -d "$FFMPEG_BIN" | grep "NEEDED" | awk '{print $5}' | tr -d '[]')
    
    # Check for critical libraries
    if echo "$DEPS" | grep -q "librockchip_mpp"; then
        echo -e "${GREEN}✓ MPP library linked${NC} (librockchip_mpp.so)"
    else
        echo -e "${RED}✗ MPP library NOT linked!${NC}"
        exit 1
    fi
    
    if echo "$DEPS" | grep -q "librga"; then
        echo -e "${GREEN}✓ RGA library linked${NC} (librga.so)"
    else
        echo -e "${RED}✗ RGA library NOT linked!${NC}"
        exit 1
    fi
    
    if echo "$DEPS" | grep -q "libdrm"; then
        echo -e "${GREEN}✓ DRM library linked${NC} (libdrm.so)"
    else
        echo -e "${YELLOW}⚠ DRM library not linked${NC}"
    fi
    
    echo ""
    echo "  All dependencies:"
    echo "$DEPS" | while read -r dep; do
        echo "    - $dep"
    done
fi

echo ""

# 4. Check for MPP/RGA codec strings
echo -e "${BLUE}4. Checking for Rockchip codecs/filters...${NC}"

CODECS=$(strings "$FFMPEG_BIN" | grep -E "^(h264|hevc|vp8|vp9|av1)_rkmpp$")
if [ -n "$CODECS" ]; then
    echo -e "${GREEN}✓ MPP codecs found:${NC}"
    echo "$CODECS" | while read -r codec; do
        echo "    - $codec"
    done
else
    echo -e "${RED}✗ No MPP codecs found!${NC}"
    exit 1
fi

echo ""

FILTERS=$(strings "$FFMPEG_BIN" | grep -E "^(scale|vpp|overlay|transpose)_rkrga$")
if [ -n "$FILTERS" ]; then
    echo -e "${GREEN}✓ RGA filters found:${NC}"
    echo "$FILTERS" | while read -r filter; do
        echo "    - $filter"
    done
else
    echo -e "${RED}✗ No RGA filters found!${NC}"
    exit 1
fi

echo ""

# 5. Check library files
echo -e "${BLUE}5. Checking installed libraries...${NC}"

LIB_DIR="$INSTALL_DIR/lib"
if [ -d "$LIB_DIR" ]; then
    LIB_COUNT=$(find "$LIB_DIR" -name "libav*.a" -o -name "libsw*.a" | wc -l)
    echo -e "${GREEN}✓ Found $LIB_COUNT FFmpeg libraries${NC}"
    
    TOTAL_SIZE=$(du -sh "$LIB_DIR" | cut -f1)
    echo "  Total library size: $TOTAL_SIZE"
    
    # List libraries
    echo "  Libraries:"
    find "$LIB_DIR" -name "libav*.a" -o -name "libsw*.a" -o -name "libpost*.a" | while read -r lib; do
        SIZE=$(du -h "$lib" | cut -f1)
        NAME=$(basename "$lib")
        echo "    - $NAME ($SIZE)"
    done
else
    echo -e "${YELLOW}⚠ Library directory not found${NC}"
fi

echo ""

# 6. Check pkg-config files
echo -e "${BLUE}6. Checking pkg-config files...${NC}"

PC_DIR="$LIB_DIR/pkgconfig"
if [ -d "$PC_DIR" ]; then
    PC_COUNT=$(find "$PC_DIR" -name "*.pc" | wc -l)
    echo -e "${GREEN}✓ Found $PC_COUNT pkg-config files${NC}"
    
    find "$PC_DIR" -name "*.pc" | while read -r pc; do
        NAME=$(basename "$pc")
        VERSION=$(grep "^Version:" "$pc" | awk '{print $2}')
        echo "    - $NAME (v$VERSION)"
    done
else
    echo -e "${YELLOW}⚠ pkg-config directory not found${NC}"
fi

echo ""

# 7. Summary
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "${GREEN}✓ Build Verification Complete!${NC}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Your FFmpeg-Rockchip build is ready for deployment to RV1126B-P!"
echo ""
echo "Next steps:"
echo "  1. Create deployment package:"
echo "     cd $INSTALL_DIR"
echo "     tar czf ffmpeg-rv1126b-\$(date +%Y%m%d).tar.gz bin/"
echo ""
echo "  2. When you receive your RV1126B-P device:"
echo "     - Transfer the tarball to the device"
echo "     - Extract to /usr/local: tar xzf ffmpeg-*.tar.gz -C /usr/local"
echo "     - Test: ffmpeg -decoders | grep rkmpp"
echo ""
echo "  3. See deployment guide:"
echo "     https://github.com/Fanconn-RV1126B-P/RV1126B-P-Docs"
echo ""
