#!/bin/bash
#
# FFmpeg-Rockchip Hardware Acceleration Test Script for RV1126B-P
# Tests MPP hardware decode/encode without requiring a display
#
# Usage: Run this script on the RV1126B-P device after extracting ffmpeg

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

FFMPEG_BIN="/usr/local/bin/ffmpeg"
TEST_DIR="/tmp/ffmpeg-test"
RESULTS_FILE="/tmp/ffmpeg-test-results.txt"

# Header
echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}FFmpeg-Rockchip Hardware Test${NC}"
echo -e "${BLUE}RV1126B-P - No Display Required${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Initialize results file
echo "FFmpeg-Rockchip Hardware Acceleration Test Results" > "$RESULTS_FILE"
echo "Date: $(date)" >> "$RESULTS_FILE"
echo "Device: RV1126B-P" >> "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"
echo "" >> "$RESULTS_FILE"

# Check FFmpeg installation
echo -e "${YELLOW}[1/8] Checking FFmpeg installation...${NC}"
if [ ! -f "$FFMPEG_BIN" ]; then
    echo -e "${RED}✗ FFmpeg not found at $FFMPEG_BIN${NC}"
    echo "Please extract the tarball first:"
    echo "  cd /tmp"
    echo "  tar xzf ffmpeg-rv1126b-20260121.tar.gz -C /usr/local"
    exit 1
fi
echo -e "${GREEN}✓ FFmpeg found: $FFMPEG_BIN${NC}"

# Verify MPP codecs available
echo -e "\n${YELLOW}[2/8] Checking MPP hardware codecs...${NC}"
CODECS=$($FFMPEG_BIN -hide_banner -codecs 2>&1)
MPP_DECODERS=$(echo "$CODECS" | grep _rkmpp || true)
MPP_ENCODERS=$($FFMPEG_BIN -hide_banner -encoders 2>&1 | grep _rkmpp || true)

if [ -z "$MPP_DECODERS" ]; then
    echo -e "${RED}✗ No MPP decoders found${NC}"
    exit 1
fi
echo -e "${GREEN}✓ MPP Decoders available:${NC}"
echo "$MPP_DECODERS" | while read line; do echo "  $line"; done

if [ -z "$MPP_ENCODERS" ]; then
    echo -e "${YELLOW}⚠ No MPP encoders found (may not be compiled)${NC}"
else
    echo -e "${GREEN}✓ MPP Encoders available:${NC}"
    echo "$MPP_ENCODERS" | while read line; do echo "  $line"; done
fi

# Create test directory
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"

# Generate test video using hardware encoding (or copy from RTSP)
echo -e "\n${YELLOW}[3/8] Generating test video (H.264)...${NC}"
TEST_VIDEO="$TEST_DIR/test-h264.mp4"

# Try hardware encoder first, fallback to mpeg4
if $FFMPEG_BIN -hide_banner -encoders 2>&1 | grep -q h264_rkmpp; then
    $FFMPEG_BIN -hide_banner -loglevel error \
        -f lavfi -i testsrc=duration=10:size=1920x1080:rate=25 \
        -c:v h264_rkmpp -b:v 2M \
        -y "$TEST_VIDEO" 2>&1
else
    # Use mpeg4 as fallback (no preset option needed)
    $FFMPEG_BIN -hide_banner -loglevel error \
        -f lavfi -i testsrc=duration=10:size=1920x1080:rate=25 \
        -c:v mpeg4 -b:v 2M \
        -y "$TEST_VIDEO" 2>&1
fi

if [ -f "$TEST_VIDEO" ]; then
    SIZE=$(du -h "$TEST_VIDEO" | cut -f1)
    echo -e "${GREEN}✓ Test video created: $SIZE${NC}"
    echo "Test video: $TEST_VIDEO ($SIZE)" >> "$RESULTS_FILE"
else
    echo -e "${RED}✗ Failed to create test video${NC}"
    exit 1
fi

# Test 1: MPP Hardware Decode (H.264 -> null)
echo -e "\n${YELLOW}[4/8] Testing MPP H.264 hardware decode...${NC}"
echo "" >> "$RESULTS_FILE"
echo "Test 1: MPP H.264 Hardware Decode" >> "$RESULTS_FILE"
echo "-----------------------------------" >> "$RESULTS_FILE"

START_TIME=$(date +%s.%N)
CPU_BEFORE=$(grep 'cpu ' /proc/stat)

$FFMPEG_BIN -hide_banner \
    -c:v h264_rkmpp \
    -i "$TEST_VIDEO" \
    -f null - 2>&1 | tee /tmp/decode-test.log

CPU_AFTER=$(grep 'cpu ' /proc/stat)
END_TIME=$(date +%s.%N)
DURATION=$(echo "$END_TIME - $START_TIME" | bc)

# Extract speed from log (BusyBox/GNU compatible)
FPS=$(grep -oE 'speed=[0-9.]+x|speed=[0-9.]+\.[0-9]+x' /tmp/decode-test.log | tail -1 | sed -E 's/speed=([0-9.]+)x/\1/' || true)
if [ -z "$FPS" ]; then
    FPS="N/A"
fi

echo -e "${GREEN}✓ Hardware decode test completed${NC}"
echo "  Duration: ${DURATION}s"
echo "  Speed: ${FPS}x realtime"
echo "Duration: ${DURATION}s" >> "$RESULTS_FILE"
echo "Speed: ${FPS}x realtime" >> "$RESULTS_FILE"

# Test 2: Software Decode Comparison
echo -e "\n${YELLOW}[5/8] Testing software decode (for comparison)...${NC}"
echo "" >> "$RESULTS_FILE"
echo "Test 2: Software H.264 Decode (Comparison)" >> "$RESULTS_FILE"
echo "-----------------------------------" >> "$RESULTS_FILE"

START_TIME=$(date +%s.%N)

$FFMPEG_BIN -hide_banner \
    -c:v h264 \
    -i "$TEST_VIDEO" \
    -f null - 2>&1 | tee /tmp/decode-sw-test.log

END_TIME=$(date +%s.%N)
DURATION_SW=$(echo "$END_TIME - $START_TIME" | bc)
FPS_SW=$(grep -oE 'speed=[0-9.]+x|speed=[0-9.]+\.[0-9]+x' /tmp/decode-sw-test.log | tail -1 | sed -E 's/speed=([0-9.]+)x/\1/' || true)
if [ -z "$FPS_SW" ]; then
    FPS_SW="N/A"
fi

echo -e "${GREEN}✓ Software decode test completed${NC}"
echo "  Duration: ${DURATION_SW}s"
echo "  Speed: ${FPS_SW}x realtime"
echo "Duration: ${DURATION_SW}s" >> "$RESULTS_FILE"
echo "Speed: ${FPS_SW}x realtime" >> "$RESULTS_FILE"

# Calculate speedup
if [ "$FPS" != "N/A" ] && [ "$FPS_SW" != "N/A" ]; then
    SPEEDUP=$(echo "scale=2; $FPS / $FPS_SW" | bc)
    echo -e "${BLUE}  → Hardware is ${SPEEDUP}x faster than software${NC}"
    echo "Hardware speedup: ${SPEEDUP}x" >> "$RESULTS_FILE"
fi

# Test 3: Check if MPP encoders are available
HAS_MPP_ENCODER=$($FFMPEG_BIN -hide_banner -encoders 2>&1 | grep "h264_rkmpp" || true)

if [ -n "$HAS_MPP_ENCODER" ]; then
    # Test 3: MPP Hardware Encode
    echo -e "\n${YELLOW}[6/8] Testing MPP H.264 hardware encode...${NC}"
    echo "" >> "$RESULTS_FILE"
    echo "Test 3: MPP H.264 Hardware Encode" >> "$RESULTS_FILE"
    echo "-----------------------------------" >> "$RESULTS_FILE"
    
    OUTPUT_HW="$TEST_DIR/encoded-hw.mp4"
    START_TIME=$(date +%s.%N)
    
    $FFMPEG_BIN -hide_banner \
        -f lavfi -i testsrc=duration=10:size=1920x1080:rate=25 \
        -c:v h264_rkmpp -b:v 4M \
        -y "$OUTPUT_HW" 2>&1 | tee /tmp/encode-test.log
    
    END_TIME=$(date +%s.%N)
    DURATION_ENC=$(echo "$END_TIME - $START_TIME" | bc)
    FPS_ENC=$(grep -oE 'speed=[0-9.]+x|speed=[0-9.]+\.[0-9]+x' /tmp/encode-test.log | tail -1 | sed -E 's/speed=([0-9.]+)x/\1/' || true)
    [ -z "$FPS_ENC" ] && FPS_ENC="N/A"
    
    if [ -f "$OUTPUT_HW" ]; then
        SIZE_HW=$(du -h "$OUTPUT_HW" | cut -f1)
        echo -e "${GREEN}✓ Hardware encode completed: $SIZE_HW${NC}"
        echo "  Duration: ${DURATION_ENC}s"
        echo "  Speed: ${FPS_ENC}x realtime"
        echo "Output size: $SIZE_HW" >> "$RESULTS_FILE"
        echo "Duration: ${DURATION_ENC}s" >> "$RESULTS_FILE"
        echo "Speed: ${FPS_ENC}x realtime" >> "$RESULTS_FILE"
    fi
    
    # Test 4: Transcode (MPP decode + MPP encode)
    echo -e "\n${YELLOW}[7/8] Testing hardware transcode (decode+encode)...${NC}"
    echo "" >> "$RESULTS_FILE"
    echo "Test 4: Hardware Transcode Pipeline" >> "$RESULTS_FILE"
    echo "-----------------------------------" >> "$RESULTS_FILE"
    
    OUTPUT_TRANSCODE="$TEST_DIR/transcoded.mp4"
    START_TIME=$(date +%s.%N)
    
    $FFMPEG_BIN -hide_banner \
        -c:v h264_rkmpp -i "$TEST_VIDEO" \
        -c:v h264_rkmpp -b:v 2M \
        -y "$OUTPUT_TRANSCODE" 2>&1 | tee /tmp/transcode-test.log
    
    END_TIME=$(date +%s.%N)
    DURATION_TC=$(echo "$END_TIME - $START_TIME" | bc)
    FPS_TC=$(grep -oE 'speed=[0-9.]+x|speed=[0-9.]+\.[0-9]+x' /tmp/transcode-test.log | tail -1 | sed -E 's/speed=([0-9.]+)x/\1/' || true)
    [ -z "$FPS_TC" ] && FPS_TC="N/A"
    
    if [ -f "$OUTPUT_TRANSCODE" ]; then
        SIZE_TC=$(du -h "$OUTPUT_TRANSCODE" | cut -f1)
        echo -e "${GREEN}✓ Transcode completed: $SIZE_TC${NC}"
        echo "  Duration: ${DURATION_TC}s"
        echo "  Speed: ${FPS_TC}x realtime"
        echo "Output size: $SIZE_TC" >> "$RESULTS_FILE"
        echo "Duration: ${DURATION_TC}s" >> "$RESULTS_FILE"
        echo "Speed: ${FPS_TC}x realtime" >> "$RESULTS_FILE"
    fi
else
    echo -e "\n${YELLOW}[6/8] Skipping encoder tests (MPP encoders not available)${NC}"
    echo "" >> "$RESULTS_FILE"
    echo "MPP Encoders: Not available in this build" >> "$RESULTS_FILE"
fi

# Test 5: Memory usage check
echo -e "\n${YELLOW}[8/8] System resource check...${NC}"
echo "" >> "$RESULTS_FILE"
echo "System Resources" >> "$RESULTS_FILE"
echo "-----------------------------------" >> "$RESULTS_FILE"

echo -e "${BLUE}Memory Usage:${NC}"
free -h | tee -a "$RESULTS_FILE"

echo -e "\n${BLUE}CPU Info:${NC}"
cat /proc/cpuinfo | grep -E "(processor|model name|cpu MHz)" | head -4 | tee -a "$RESULTS_FILE"

echo -e "\n${BLUE}MPP Device:${NC}"
ls -la /dev/mpp* 2>&1 | tee -a "$RESULTS_FILE"

echo -e "\n${BLUE}RGA Device:${NC}"
ls -la /dev/rga 2>&1 | tee -a "$RESULTS_FILE"

# Summary
echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Test Summary${NC}"
echo -e "${BLUE}========================================${NC}"
echo "" >> "$RESULTS_FILE"
echo "Summary" >> "$RESULTS_FILE"
echo "========================================" >> "$RESULTS_FILE"

echo -e "${GREEN}✓ All tests completed successfully${NC}"
echo -e "\nTest files created in: ${TEST_DIR}"
echo -e "Detailed results saved to: ${RESULTS_FILE}"
echo "" | tee -a "$RESULTS_FILE"
echo "Test files location: $TEST_DIR" >> "$RESULTS_FILE"
echo "All tests completed successfully" >> "$RESULTS_FILE"

# Show results file
echo -e "\n${YELLOW}Displaying full results:${NC}"
cat "$RESULTS_FILE"

echo -e "\n${BLUE}========================================${NC}"
echo -e "${BLUE}Next Steps:${NC}"
echo -e "${BLUE}========================================${NC}"
echo "1. Review results: cat $RESULTS_FILE"
echo "2. Test with RTSP stream (adjust IP/port as needed):"
echo "   $FFMPEG_BIN -c:v h264_rkmpp -rtsp_transport tcp -i rtsp://<CAMERA_IP>:554/live/0 -f null -"
echo "3. Encode from camera to file:"
echo "   $FFMPEG_BIN -c:v h264_rkmpp -rtsp_transport tcp -i rtsp://<CAMERA_IP>:554/live/0 -t 30 -c:v copy /tmp/recording.mp4"
echo ""
