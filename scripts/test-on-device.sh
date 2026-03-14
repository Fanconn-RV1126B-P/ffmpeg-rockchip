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

# ── Helpers ───────────────────────────────────────────────────────────
# hw_decode_test <decoder> <input_file> <label>
hw_decode_test() {
    _dc="$1"; _in="$2"; _lbl="${3:-$1}"
    if ! echo "$HW_DECODERS" | grep -qw "$_dc"; then
        result_skip "HW decode [$_lbl] (not compiled)"; return
    fi
    if [ ! -f "$_in" ]; then
        result_skip "HW decode [$_lbl] (no test source)"; return
    fi
    _log="$TEST_DIR/dec-${_dc}.log"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v "$_dc" -i "$_in" -f null - 2>"$_log" || true
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "HW decode [$_lbl] speed:${_spd:-N/A}"
    else
        result_fail "HW decode [$_lbl] (see $_log)"
    fi
}

# hw_encode_test <encoder> <lavfi_src> <output_file> <extra_args> <label>
hw_encode_test() {
    _ec="$1"; _src="$2"; _out="$3"; _extra="$4"; _lbl="${5:-$1}"
    if ! echo "$HW_ENCODERS" | grep -qw "$_ec"; then
        result_skip "HW encode [$_lbl] (not compiled)"; return
    fi
    _log="$TEST_DIR/enc-${_ec}.log"
    # shellcheck disable=SC2086
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "$_src" \
        -c:v "$_ec" $_extra \
        "$_out" 2>"$_log" || true
    if [ -f "$_out" ] && [ -s "$_out" ]; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        _sz=$(du -h "$_out" | cut -f1)
        result_pass "HW encode [$_lbl] speed:${_spd:-N/A} size:$_sz"
    else
        result_fail "HW encode [$_lbl] (see $_log)"
    fi
}

# ── [5] Generate decode test sources ─────────────────────────────────
printf "\n${YELLOW}[5] Generate decode test sources${NC}\n"
LAVFI_HD="testsrc=duration=5:size=1280x720:rate=25,format=yuv420p"
LAVFI_CIF="testsrc=duration=5:size=352x288:rate=25,format=yuv420p"

# H.264 — already built in section [4]
SRC_H264="$TEST_SRC"

# H.265
SRC_H265="$TEST_DIR/src-h265.mp4"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v hevc_rkmpp -b:v 1M "$SRC_H265" 2>/dev/null || \
   "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v libx265 -b:v 1M -x265-params "log-level=error" "$SRC_H265" 2>/dev/null; then
    info "H.265 source: ok"
else
    warn "H.265 source: skipped (no hevc encoder)"
fi

# VP9
SRC_VP9="$TEST_DIR/src-vp9.webm"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v vp9_rkmpp -b:v 1M "$SRC_VP9" 2>/dev/null; then
    info "VP9 source: ok (hw)"
else
    warn "VP9 source: skipped (no vp9_rkmpp encoder)"
fi

# VP8
SRC_VP8="$TEST_DIR/src-vp8.webm"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v vp8_rkmpp -b:v 1M "$SRC_VP8" 2>/dev/null; then
    info "VP8 source: ok (hw)"
else
    warn "VP8 source: skipped (no vp8_rkmpp encoder)"
fi

# MPEG-4 (software encoder built in)
SRC_MPEG4="$TEST_DIR/src-mpeg4.mp4"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v mpeg4 -b:v 1M "$SRC_MPEG4" 2>/dev/null; then
    info "MPEG-4 source: ok"
else
    warn "MPEG-4 source: skipped"
fi

# MPEG-2 (software encoder built in)
SRC_MPEG2="$TEST_DIR/src-mpeg2.mpg"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v mpeg2video -b:v 2M "$SRC_MPEG2" 2>/dev/null; then
    info "MPEG-2 source: ok"
else
    warn "MPEG-2 source: skipped"
fi

# MPEG-1 (software encoder built in)
SRC_MPEG1="$TEST_DIR/src-mpeg1.mpg"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v mpeg1video -b:v 2M "$SRC_MPEG1" 2>/dev/null; then
    info "MPEG-1 source: ok"
else
    warn "MPEG-1 source: skipped"
fi

# MJPEG (software encoder built in, .avi container)
SRC_MJPEG="$TEST_DIR/src-mjpeg.avi"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v mjpeg -q:v 3 "$SRC_MJPEG" 2>/dev/null; then
    info "MJPEG source: ok"
else
    warn "MJPEG source: skipped"
fi

# H.263 — must use CIF resolution (352x288)
SRC_H263="$TEST_DIR/src-h263.avi"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_CIF" -c:v h263 -b:v 256k "$SRC_H263" 2>/dev/null; then
    info "H.263 source: ok"
else
    warn "H.263 source: skipped"
fi

# AV1 — libaom too slow on aarch64 for automated test; skip source generation
SRC_AV1=""
warn "AV1 decode source: skipped (libaom-av1 too slow — provide a real AV1 file for manual test)"

# VC-1 / AVS2 — no practical software encoder in FFmpeg
warn "VC-1 / AVS2 decode source: skipped (no software encoder — provide real files for manual test)"

result_pass "Decode source generation complete"

# ── [6] Hardware decode — all supported codecs ─────────────────────────
printf "\n${YELLOW}[6] Hardware decode -- all supported codecs${NC}\n"
hw_decode_test "h264_rkmpp"       "$SRC_H264"  "H.264"
hw_decode_test "hevc_rkmpp"       "$SRC_H265"  "H.265"
hw_decode_test "vp9_rkmpp"        "$SRC_VP9"   "VP9"
hw_decode_test "vp8_rkmpp"        "$SRC_VP8"   "VP8"
hw_decode_test "mpeg4_rkmpp"      "$SRC_MPEG4" "MPEG-4"
hw_decode_test "mpeg2video_rkmpp" "$SRC_MPEG2" "MPEG-2"
hw_decode_test "mpeg1video_rkmpp" "$SRC_MPEG1" "MPEG-1"
hw_decode_test "mjpeg_rkmpp"      "$SRC_MJPEG" "MJPEG"
hw_decode_test "h263_rkmpp"       "$SRC_H263"  "H.263"
# AV1 / VC-1 / AVS2 — no generated source; skip gracefully
hw_decode_test "av1_rkmpp"        "$SRC_AV1"   "AV1 (no auto source)"
result_skip "HW decode [VC-1] (no vc1 source -- provide a real .wmv file)"
result_skip "HW decode [AVS2] (no avs2 source -- provide a real AVS2 file)"
result_skip "HW decode [AVS/AVS+] (no avs source -- provide a real AVS file)"

# ── [7] Hardware encode — all supported codecs ─────────────────────────
# RV1126B MPP encode: H.264, H.265, VP8, MJPEG
printf "\n${YELLOW}[7] Hardware encode -- all supported codecs${NC}\n"
hw_encode_test "h264_rkmpp"  "$LAVFI_HD"  "$TEST_DIR/enc-h264.mp4"  "-b:v 2M"       "H.264"
hw_encode_test "hevc_rkmpp"  "$LAVFI_HD"  "$TEST_DIR/enc-h265.mp4"  "-b:v 2M"       "H.265"
hw_encode_test "vp8_rkmpp"   "$LAVFI_HD"  "$TEST_DIR/enc-vp8.webm"  "-b:v 1M"       "VP8"
hw_encode_test "mjpeg_rkmpp" "$LAVFI_HD"  "$TEST_DIR/enc-mjpeg.avi" "-q:v 3 -b:v 0" "MJPEG"

# ── [8] Hardware transcode pipelines ──────────────────────────────────
printf "\n${YELLOW}[8] Hardware transcode pipelines${NC}\n"
# H.264 -> H.264
if echo "$HW_DECODERS" | grep -qw h264_rkmpp && \
   echo "$HW_ENCODERS" | grep -qw h264_rkmpp && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/tc-h264-h264.log"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/tc-h264-h264.mp4" 2>"$_log" || true
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "Transcode H.264->H.264 speed:${_spd:-N/A}"
    else
        result_fail "Transcode H.264->H.264 (see $_log)"
    fi
else
    result_skip "Transcode H.264->H.264 (missing encoder/decoder)"
fi

# H.264 -> H.265
if echo "$HW_DECODERS" | grep -qw h264_rkmpp && \
   echo "$HW_ENCODERS" | grep -qw hevc_rkmpp && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/tc-h264-h265.log"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" -c:v hevc_rkmpp -b:v 1M \
        "$TEST_DIR/tc-h264-h265.mp4" 2>"$_log" || true
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "Transcode H.264->H.265 speed:${_spd:-N/A}"
    else
        result_fail "Transcode H.264->H.265 (see $_log)"
    fi
else
    result_skip "Transcode H.264->H.265 (missing encoder/decoder)"
fi

# H.265 -> H.264
if echo "$HW_DECODERS" | grep -qw hevc_rkmpp && \
   echo "$HW_ENCODERS" | grep -qw h264_rkmpp && [ -f "$SRC_H265" ]; then
    _log="$TEST_DIR/tc-h265-h264.log"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v hevc_rkmpp -i "$SRC_H265" -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/tc-h265-h264.mp4" 2>"$_log" || true
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "Transcode H.265->H.264 speed:${_spd:-N/A}"
    else
        result_fail "Transcode H.265->H.264 (see $_log)"
    fi
else
    result_skip "Transcode H.265->H.264 (missing encoder/decoder)"
fi

# ── [9] RGA video processing ──────────────────────────────────────────
printf "\n${YELLOW}[9] RGA video processing${NC}\n"
RGA_FILTERS=$("$FFMPEG" -hide_banner -filters 2>&1 | grep rkrga | awk '{print $2}' | tr '\n' ' ')
if [ -n "$RGA_FILTERS" ]; then
    result_pass "RGA filters available: $RGA_FILTERS"
else
    warn "No RGA filters found (scale_rkrga / yadif_rkrga tests will be skipped)"
fi

# Scale / zoom via scale_rkrga
if echo "$RGA_FILTERS" | grep -q scale_rkrga && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/rga-scale.log"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" \
        -vf "scale_rkrga=640:360" \
        -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/rga-scale.mp4" 2>"$_log" || true
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "RGA scale 1280x720->640x360 speed:${_spd:-N/A}"
    else
        result_fail "RGA scale (see $_log)"
    fi
else
    result_skip "RGA scale (no scale_rkrga or no H.264 source)"
fi

# Color space conversion: yuv420p -> nv12 via scale_rkrga
if echo "$RGA_FILTERS" | grep -q scale_rkrga && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/rga-csc.log"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" \
        -vf "scale_rkrga=1280:720:format=nv12" \
        -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/rga-csc.mp4" 2>"$_log" || true
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "RGA color space conversion (yuv420p->nv12) speed:${_spd:-N/A}"
    else
        result_fail "RGA color space conversion (see $_log)"
    fi
else
    result_skip "RGA color space conversion (no scale_rkrga or no H.264 source)"
fi

# Deinterlace via yadif_rkrga
if echo "$RGA_FILTERS" | grep -q yadif_rkrga; then
    SRC_INTL="$TEST_DIR/src-interlaced.mp4"
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "testsrc=duration=5:size=1280x720:rate=25,format=yuv420p" \
        -vf "interlace" -c:v h264_rkmpp -b:v 1M \
        "$SRC_INTL" 2>/dev/null || true
    if [ -f "$SRC_INTL" ] && [ -s "$SRC_INTL" ]; then
        _log="$TEST_DIR/rga-deinterlace.log"
        "$FFMPEG" -hide_banner -loglevel info -y \
            -c:v h264_rkmpp -i "$SRC_INTL" \
            -vf "yadif_rkrga=mode=0" \
            -c:v h264_rkmpp -b:v 1M \
            "$TEST_DIR/rga-deinterlace.mp4" 2>"$_log" || true
        if grep -qE 'frame=|Output #0' "$_log"; then
            _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
            result_pass "RGA deinterlace (yadif_rkrga) speed:${_spd:-N/A}"
        else
            result_fail "RGA deinterlace (see $_log)"
        fi
    else
        result_skip "RGA deinterlace (could not generate interlaced source)"
    fi
else
    result_skip "RGA deinterlace (no yadif_rkrga filter)"
fi

# ── [10] Software codecs (rkmpp_software profile only) ────────────────
printf "\n${YELLOW}[10] Software codecs (rkmpp_software profile)${NC}\n"
SW_ENCODERS=$("$FFMPEG" -hide_banner -encoders 2>&1)

for codec in libx264 libx265; do
    if echo "$SW_ENCODERS" | grep -q "$codec"; then
        OUT_SW="$TEST_DIR/sw-${codec}.mp4"
        LOG="$TEST_DIR/sw-${codec}.log"
        "$FFMPEG" -hide_banner -loglevel warning -y \
            -f lavfi -i "testsrc=duration=3:size=640x360:rate=25,format=yuv420p" \
            -c:v "$codec" -b:v 500k \
            "$OUT_SW" 2>"$LOG" || true
        if [ -f "$OUT_SW" ] && [ -s "$OUT_SW" ]; then
            SIZE=$(du -h "$OUT_SW" | cut -f1)
            result_pass "SW encode: $codec ($SIZE)"
        else
            result_fail "SW encode: $codec (check $LOG)"
        fi
    else
        result_skip "SW encode: $codec (not compiled)"
    fi
done

for codec in libvpx libvpx-vp9; do
    if echo "$SW_ENCODERS" | grep -q "$codec"; then
        OUT_SW="$TEST_DIR/sw-${codec}.webm"
        LOG="$TEST_DIR/sw-${codec}.log"
        "$FFMPEG" -hide_banner -loglevel warning -y \
            -f lavfi -i "testsrc=duration=3:size=640x360:rate=25,format=yuv420p" \
            -c:v "$codec" -b:v 500k \
            "$OUT_SW" 2>"$LOG" || true
        if [ -f "$OUT_SW" ] && [ -s "$OUT_SW" ]; then
            SIZE=$(du -h "$OUT_SW" | cut -f1)
            result_pass "SW encode: $codec ($SIZE)"
        else
            result_fail "SW encode: $codec (check $LOG)"
        fi
    else
        result_skip "SW encode: $codec (not compiled)"
    fi
done

# libaom-av1 -- report availability only (too slow to encode as a test)
if echo "$SW_ENCODERS" | grep -q "libaom-av1"; then
    result_pass "SW codec available: libaom-av1"
else
    result_skip "SW codec: libaom-av1 (not compiled)"
fi

# ── [11] System resources ─────────────────────────────────────────────
printf "\n${YELLOW}[11] System resources${NC}\n"
info "Memory:"
free -h 2>/dev/null || grep -E 'MemTotal|MemFree|MemAvailable' /proc/meminfo || true
info "Load:"
cat /proc/loadavg 2>/dev/null || true
result_pass "System resource check"

# ── Summary ───────────────────────────────────────────────────────────
printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BLUE}  Test Summary${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed: %d${NC}  ${RED}Failed: %d${NC}  ${YELLOW}Skipped: %d${NC}\n" "$PASS" "$FAIL" "$SKIP"
printf "  Results : %s\n" "$RESULTS_FILE"
printf "  Log dir : %s\n" "$TEST_DIR"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

printf "SUMMARY: PASS=%d FAIL=%d SKIP=%d\n" "$PASS" "$FAIL" "$SKIP" >> "$RESULTS_FILE"

if [ "$FAIL" -gt 0 ]; then
    printf "${RED}Some tests failed. Check logs in %s${NC}\n\n" "$TEST_DIR"
    exit 1
else
    printf "${GREEN}All tests passed!${NC}\n\n"
fi
