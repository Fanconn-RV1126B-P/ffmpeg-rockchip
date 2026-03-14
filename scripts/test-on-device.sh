#!/bin/sh
#
# test-on-device.sh
# FFmpeg-Rockchip hardware and software codec test suite for RV1126B-P
#
# Usage (from host PC):
#   sh scripts/test-on-device.sh <DEVICE_IP>
#   DEVICE_IP=192.168.1.95 sh scripts/test-on-device.sh
#
# Usage (directly on device):
#   sh /usr/local/ffmpeg-rv1126b/test-on-device.sh

set -e

# ── Remote dispatch ───────────────────────────────────────────────────
# If called with a device IP from a non-aarch64 host, copy self to the
# device and execute there, then stream output back.
_DEVICE_IP="${1:-${DEVICE_IP:-}}"
_DEVICE_USER="${DEVICE_USER:-root}"
if [ -n "$_DEVICE_IP" ] && [ "$(uname -m)" != "aarch64" ]; then
    REMOTE="${_DEVICE_USER}@${_DEVICE_IP}"
    printf "[+] Remote mode: streaming test suite on %s\n" "$REMOTE"
    _SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
    scp -q "$_SELF" "${REMOTE}:/tmp/_test-on-device-run.sh"
    ssh -t -o BatchMode=no "$REMOTE" \
        'sh /tmp/_test-on-device-run.sh; _rc=$?; rm -f /tmp/_test-on-device-run.sh; exit $_rc'
    exit $?
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { printf "${BLUE}[+]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error()   { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }
skip()    { printf "${YELLOW}[-]${NC} %s\n" "$*"; }

TEST_DIR="/tmp/ffmpeg-rv1126b-test"
RESULTS_FILE="/tmp/ffmpeg-rv1126b-test-results.txt"
PASS=0; FAIL=0; SKIP=0

result_pass() { PASS=$((PASS+1)); success "$1"; echo "PASS: $1" >> "$RESULTS_FILE"; }
result_fail() { FAIL=$((FAIL+1)); printf "${RED}[✗]${NC} %s\n" "$1"; echo "FAIL: $1" >> "$RESULTS_FILE"; }
result_skip() { SKIP=$((SKIP+1)); skip   "$1"; echo "SKIP: $1" >> "$RESULTS_FILE"; }

# ── Auto-detect ffmpeg binary ─────────────────────────────────────────
find_ffmpeg() {
    for candidate in \
        /usr/local/ffmpeg-rv1126b/bin/ffmpeg-rv1126b \
        /usr/local/ffmpeg-rv1126b/bin/ffmpeg \
        /usr/local/bin/ffmpeg \
        /usr/bin/ffmpeg \
        ffmpeg
    do
        if command -v "$candidate" >/dev/null 2>&1 || [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

FFMPEG=$(find_ffmpeg) || error "ffmpeg not found. Run install-ffmpeg-rv1126b.sh first."
FFPROBE=$(dirname "$FFMPEG")/ffprobe
[ -x "$FFPROBE" ] || FFPROBE=$(dirname "$FFMPEG")/ffprobe-rv1126b
[ -x "$FFPROBE" ] || FFPROBE=""

printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BLUE}  FFmpeg-Rockchip Test Suite — RV1126B-P${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"
info "FFmpeg binary : $FFMPEG"
info "Test dir      : $TEST_DIR"
printf "\n"

mkdir -p "$TEST_DIR"
: > "$RESULTS_FILE"
printf "FFmpeg-Rockchip Test Results — $(date)\n" >> "$RESULTS_FILE"
printf "Binary: %s\n" "$FFMPEG" >> "$RESULTS_FILE"
printf "======================================\n\n" >> "$RESULTS_FILE"

# ── [1] Version check ─────────────────────────────────────────────────
printf "${YELLOW}[1] FFmpeg version${NC}\n"
if "$FFMPEG" -version 2>&1 | head -1 | grep -q ffmpeg; then
    "$FFMPEG" -version 2>&1 | head -1
    result_pass "ffmpeg version check"
else
    result_fail "ffmpeg version check"
fi

# ── [2] Hardware device nodes ─────────────────────────────────────────
printf "\n${YELLOW}[2] Rockchip device nodes${NC}\n"
for dev in /dev/mpp_service /dev/rga; do
    if [ -e "$dev" ]; then
        result_pass "Device node: $dev"
    else
        warn "Device node not found: $dev (hardware tests may fail)"
        echo "WARN: $dev not found" >> "$RESULTS_FILE"
    fi
done

# ── [3] MPP hardware codecs ───────────────────────────────────────────
printf "\n${YELLOW}[3] MPP hardware codecs${NC}\n"
HW_DECODERS=$("$FFMPEG" -hide_banner -decoders 2>&1 | grep _rkmpp | awk '{print $2}' | tr '\n' ' ')
HW_ENCODERS=$("$FFMPEG" -hide_banner -encoders 2>&1 | grep _rkmpp | awk '{print $2}' | tr '\n' ' ')
RGA_FILTERS=$("$FFMPEG" -hide_banner -filters 2>&1 | grep rkrga | awk '{print $2}' | tr '\n' ' ')

if [ -n "$HW_DECODERS" ]; then
    result_pass "MPP decoders: $HW_DECODERS"
else
    result_fail "No MPP decoders found"
fi
if [ -n "$HW_ENCODERS" ]; then
    result_pass "MPP encoders: $HW_ENCODERS"
else
    warn "No MPP encoders (encode tests will be skipped)"
fi
if [ -n "$RGA_FILTERS" ]; then
    result_pass "RGA filters: $RGA_FILTERS"
else
    warn "No RGA filters found"
fi

# ── [4] Generate test source video (software) ─────────────────────────
printf "\n${YELLOW}[4] Generate test source video${NC}\n"
TEST_SRC="$TEST_DIR/source.mp4"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc=duration=5:size=1280x720:rate=25" \
    -c:v libx264 -pix_fmt yuv420p -b:v 1M \
    "$TEST_SRC" 2>/dev/null || \
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc=duration=5:size=1280x720:rate=25" \
    -c:v mpeg4 -pix_fmt yuv420p -b:v 1M \
    "$TEST_SRC" 2>/dev/null || true

if [ -f "$TEST_SRC" ]; then
    SIZE=$(du -h "$TEST_SRC" | cut -f1)
    result_pass "Test source video: $SIZE"
else
    warn "Could not generate test source; some tests will be skipped"
fi

# ── [5] MPP hardware decode ───────────────────────────────────────────
printf "\n${YELLOW}[5] MPP H.264 hardware decode (h264_rkmpp)${NC}\n"
if echo "$HW_DECODERS" | grep -q h264_rkmpp && [ -f "$TEST_SRC" ]; then
    LOG="$TEST_DIR/hw-decode.log"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v h264_rkmpp -i "$TEST_SRC" -f null - 2>"$LOG" || true
    SPEED=$(grep -oE 'speed=[0-9.]+x' "$LOG" | tail -1 | sed 's/speed=//')
    if grep -q "Output #0" "$LOG" || grep -q "frame=" "$LOG"; then
        result_pass "MPP H.264 decode — speed: ${SPEED:-N/A}"
    else
        result_fail "MPP H.264 decode failed (check $LOG)"
    fi
else
    result_skip "MPP H.264 decode (no h264_rkmpp decoder or no test source)"
fi

# ── [6] MPP hardware encode ───────────────────────────────────────────
printf "\n${YELLOW}[6] MPP H.264 hardware encode (h264_rkmpp)${NC}\n"
if echo "$HW_ENCODERS" | grep -q h264_rkmpp; then
    OUT_HW="$TEST_DIR/hw-encode.mp4"
    LOG="$TEST_DIR/hw-encode.log"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "testsrc=duration=5:size=1280x720:rate=25" \
        -c:v h264_rkmpp -b:v 2M \
        "$OUT_HW" 2>"$LOG" || true
    if [ -f "$OUT_HW" ] && [ -s "$OUT_HW" ]; then
        SPEED=$(grep -oE 'speed=[0-9.]+x' "$LOG" | tail -1 | sed 's/speed=//')
        SIZE=$(du -h "$OUT_HW" | cut -f1)
        result_pass "MPP H.264 encode — speed: ${SPEED:-N/A}, size: $SIZE"
    else
        result_fail "MPP H.264 encode failed (check $LOG)"
    fi
else
    result_skip "MPP H.264 encode (no h264_rkmpp encoder)"
fi

# ── [7] MPP hardware transcode ────────────────────────────────────────
printf "\n${YELLOW}[7] MPP hardware transcode (h264_rkmpp → h264_rkmpp)${NC}\n"
if echo "$HW_DECODERS" | grep -q h264_rkmpp && \
   echo "$HW_ENCODERS" | grep -q h264_rkmpp && [ -f "$TEST_SRC" ]; then
    OUT_TC="$TEST_DIR/transcode.mp4"
    LOG="$TEST_DIR/transcode.log"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$TEST_SRC" \
        -c:v h264_rkmpp -b:v 1M \
        "$OUT_TC" 2>"$LOG" || true
    if [ -f "$OUT_TC" ] && [ -s "$OUT_TC" ]; then
        SPEED=$(grep -oE 'speed=[0-9.]+x' "$LOG" | tail -1 | sed 's/speed=//')
        result_pass "MPP transcode pipeline — speed: ${SPEED:-N/A}"
    else
        result_fail "MPP transcode failed (check $LOG)"
    fi
else
    result_skip "MPP transcode (missing rkmpp encoder/decoder)"
fi

# ── [8] Software codecs (rkmpp-sw profile) ───────────────────────────
printf "\n${YELLOW}[8] Software codecs (rkmpp-sw profile)${NC}\n"
SW_ENCODERS=$("$FFMPEG" -hide_banner -encoders 2>&1)
SW_DECODERS=$("$FFMPEG" -hide_banner -decoders 2>&1)

for codec in libx264 libx265; do
    if echo "$SW_ENCODERS" | grep -q "$codec"; then
        OUT_SW="$TEST_DIR/sw-${codec}.mp4"
        LOG="$TEST_DIR/sw-${codec}.log"
        "$FFMPEG" -hide_banner -loglevel warning -y \
            -f lavfi -i "testsrc=duration=3:size=640x360:rate=25" \
            -c:v "$codec" -b:v 500k \
            "$OUT_SW" 2>"$LOG" || true
        if [ -f "$OUT_SW" ] && [ -s "$OUT_SW" ]; then
            SIZE=$(du -h "$OUT_SW" | cut -f1)
            result_pass "Software encode: $codec ($SIZE)"
        else
            result_fail "Software encode: $codec (check $LOG)"
        fi
    else
        result_skip "Software encode: $codec (not compiled)"
    fi
done

for codec in libvpx libvpx-vp9; do
    if echo "$SW_ENCODERS" | grep -q "$codec"; then
        OUT_SW="$TEST_DIR/sw-${codec}.webm"
        LOG="$TEST_DIR/sw-${codec}.log"
        "$FFMPEG" -hide_banner -loglevel warning -y \
            -f lavfi -i "testsrc=duration=3:size=640x360:rate=25" \
            -c:v "$codec" -b:v 500k \
            "$OUT_SW" 2>"$LOG" || true
        if [ -f "$OUT_SW" ] && [ -s "$OUT_SW" ]; then
            SIZE=$(du -h "$OUT_SW" | cut -f1)
            result_pass "Software encode: $codec ($SIZE)"
        else
            result_fail "Software encode: $codec (check $LOG)"
        fi
    else
        result_skip "Software encode: $codec (not compiled)"
    fi
done

# libaom-av1 is very slow — just check it's present
if echo "$SW_ENCODERS" | grep -q "libaom-av1"; then
    result_pass "Software codec available: libaom-av1"
else
    result_skip "Software codec: libaom-av1 (not compiled)"
fi

# ── [9] System resources ──────────────────────────────────────────────
printf "\n${YELLOW}[9] System resources${NC}\n"
info "Memory:"
free -h 2>/dev/null || cat /proc/meminfo | grep -E 'MemTotal|MemFree|MemAvailable' || true
info "Load:"
cat /proc/loadavg 2>/dev/null || true
result_pass "System resource check"

# ── Summary ───────────────────────────────────────────────────────────
printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BLUE}  Test Summary${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed: %d${NC}  ${RED}Failed: %d${NC}  ${YELLOW}Skipped: %d${NC}\n" "$PASS" "$FAIL" "$SKIP"
printf "  Results: %s\n" "$RESULTS_FILE"
printf "  Test files: %s\n" "$TEST_DIR"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

printf "SUMMARY: PASS=%d FAIL=%d SKIP=%d\n" "$PASS" "$FAIL" "$SKIP" >> "$RESULTS_FILE"

if [ "$FAIL" -gt 0 ]; then
    printf "${RED}Some tests failed. Check logs in %s${NC}\n\n" "$TEST_DIR"
    exit 1
else
    printf "${GREEN}All tests passed!${NC}\n\n"
fi
