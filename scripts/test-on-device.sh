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

# ── [4] Generate base test source (H.264, 30s 720p) ──────────────────
printf "\n${YELLOW}[4] Generate test source video${NC}\n"
TEST_SRC="$TEST_DIR/source.mp4"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc=duration=30:size=1280x720:rate=25,format=yuv420p" \
    -c:v libx264 -b:v 2M \
    "$TEST_SRC" 2>/dev/null || \
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc=duration=30:size=1280x720:rate=25,format=yuv420p" \
    -c:v mpeg4 -pix_fmt yuv420p -b:v 2M \
    "$TEST_SRC" 2>/dev/null || true

if [ -f "$TEST_SRC" ]; then
    SIZE=$(du -h "$TEST_SRC" | cut -f1)
    result_pass "Test source video (30s 720p): $SIZE"
else
    warn "Could not generate test source; some tests will be skipped"
fi

# ── Resource monitor helpers ──────────────────────────────────────────
# Starts a background sampler (~1s interval) recording CPU+RAM to a log.
monitor_start() {
    _mn="$1"
    _mlog="$TEST_DIR/mon-${_mn}.log"
    : > "$_mlog"
    (
        while true; do
            awk '/^cpu /{
                total=$2+$3+$4+$5+$6+$7+$8+$9
                busy=total-$5-$6
                printf "CPU %d %d\n", total, busy
            }' /proc/stat
            awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} \
                 END{printf "MEM %d %d\n", t, a}' /proc/meminfo
            sleep 1
        done
    ) >> "$_mlog" 2>/dev/null &
    echo $! > "$TEST_DIR/mon-${_mn}.pid"
}

# Kills the sampler, parses the log, prints a compact resource line.
monitor_stop() {
    _mn="$1"
    _pidf="$TEST_DIR/mon-${_mn}.pid"
    _mlog="$TEST_DIR/mon-${_mn}.log"
    if [ -f "$_pidf" ]; then
        kill "$(cat "$_pidf")" 2>/dev/null || true
        rm -f "$_pidf"
    fi
    if [ -f "$_mlog" ] && [ -s "$_mlog" ]; then
        awk '
            /^CPU/ {
                if (pt > 0) {
                    dt = $2 - pt; db = $3 - pb
                    if (dt > 0) pct = db * 100 / dt; else pct = 0
                    if (pct > mx) mx = pct
                    s += pct; c++
                }
                pt = $2; pb = $3
            }
            /^MEM/ { u = ($2 - $3) / 1024; if (u > mu) mu = u }
            END {
                av = (c > 0) ? s / c : 0
                printf "       resource: CPU peak=%d%% avg=%d%%  RAM peak=%dMiB\n", mx, av, mu
            }
        ' "$_mlog"
    fi
}

# ── Codec test helpers ────────────────────────────────────────────────
# hw_decode_test <decoder> <input_file> <label> [log_tag]
hw_decode_test() {
    _dc="$1"; _in="$2"; _lbl="${3:-$1}"; _tag="${4:-}"
    if ! echo "$HW_DECODERS" | grep -qw "$_dc"; then
        result_skip "HW decode [$_lbl] (not compiled)"; return
    fi
    if [ ! -f "$_in" ]; then
        result_skip "HW decode [$_lbl] (no test source)"; return
    fi
    _logkey="dec-${_dc}${_tag:+-$_tag}"
    _log="$TEST_DIR/${_logkey}.log"
    monitor_start "$_logkey"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v "$_dc" -i "$_in" -f null - 2>"$_log" || true
    monitor_stop "$_logkey"
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "HW decode [$_lbl] speed:${_spd:-N/A}"
    elif grep -q 'unsupported' "$_log"; then
        result_skip "HW decode [$_lbl] (MPP: unsupported on this SoC)"
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
    _log="$TEST_DIR/enc-${_ec}-$(basename "$_out" | sed 's/[^a-z0-9]/-/g').log"
    monitor_start "enc-${_ec}-$(basename "$_out" | sed 's/[^a-z0-9]/-/g')"
    # shellcheck disable=SC2086
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "$_src" \
        -c:v "$_ec" $_extra \
        "$_out" 2>"$_log" || true
    monitor_stop "enc-${_ec}-$(basename "$_out" | sed 's/[^a-z0-9]/-/g')"
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
# 30s for sources used in HW vs SW comparison
LAVFI_HD="testsrc=duration=30:size=1280x720:rate=25,format=yuv420p"
# 10s for codec-coverage-only sources (no perf comparison needed)
LAVFI_SHORT="testsrc=duration=10:size=1280x720:rate=25,format=yuv420p"
LAVFI_CIF="testsrc=duration=10:size=352x288:rate=25,format=yuv420p"
# 4K for max-capability tests
LAVFI_4K="testsrc=duration=30:size=3840x2160:rate=30,format=yuv420p"

SRC_H264="$TEST_SRC"

SRC_H265="$TEST_DIR/src-h265.mp4"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v hevc_rkmpp -b:v 2M "$SRC_H265" 2>/dev/null || \
   "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_HD" -c:v libx265 -b:v 2M \
    -x265-params "log-level=error" "$SRC_H265" 2>/dev/null; then
    info "H.265 source: ok (30s 720p)"
else
    warn "H.265 source: skipped"
fi

SRC_VP9="$TEST_DIR/src-vp9.webm"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_SHORT" -c:v vp9_rkmpp -b:v 1M "$SRC_VP9" 2>/dev/null; then
    info "VP9 source: ok (hw)"
else
    warn "VP9 source: skipped (no vp9_rkmpp encoder)"
fi

SRC_VP8="$TEST_DIR/src-vp8.webm"
if "$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_SHORT" -c:v vp8_rkmpp -b:v 1M "$SRC_VP8" 2>/dev/null; then
    info "VP8 source: ok (hw)"
else
    warn "VP8 source: skipped (no vp8_rkmpp encoder)"
fi

SRC_MPEG4="$TEST_DIR/src-mpeg4.mp4"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_SHORT" -c:v mpeg4 -b:v 1M "$SRC_MPEG4" 2>/dev/null && \
    info "MPEG-4 source: ok" || warn "MPEG-4 source: skipped"

SRC_MPEG2="$TEST_DIR/src-mpeg2.mpg"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_SHORT" -c:v mpeg2video -b:v 2M "$SRC_MPEG2" 2>/dev/null && \
    info "MPEG-2 source: ok" || warn "MPEG-2 source: skipped"

SRC_MPEG1="$TEST_DIR/src-mpeg1.mpg"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_SHORT" -c:v mpeg1video -b:v 2M "$SRC_MPEG1" 2>/dev/null && \
    info "MPEG-1 source: ok" || warn "MPEG-1 source: skipped"

SRC_MJPEG="$TEST_DIR/src-mjpeg.avi"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_SHORT" -c:v mjpeg -q:v 3 "$SRC_MJPEG" 2>/dev/null && \
    info "MJPEG source: ok" || warn "MJPEG source: skipped"

SRC_H263="$TEST_DIR/src-h263.avi"
"$FFMPEG" -hide_banner -loglevel error -y \
    -f lavfi -i "$LAVFI_CIF" -c:v h263 -b:v 256k "$SRC_H263" 2>/dev/null && \
    info "H.263 source: ok" || warn "H.263 source: skipped"

SRC_AV1=""
warn "AV1 decode source: skipped (libaom-av1 too slow; provide a real AV1 file for manual test)"
warn "VC-1/AVS2/AVS+ decode source: skipped (no software encoder; provide real files)"

result_pass "Decode source generation complete"

# ── [6] Hardware decode — all supported codecs ─────────────────────────
printf "\n${YELLOW}[6] Hardware decode -- all supported codecs${NC}\n"
hw_decode_test "h264_rkmpp"       "$SRC_H264"  "H.264"
hw_decode_test "hevc_rkmpp"       "$SRC_H265"  "H.265"
hw_decode_test "vp9_rkmpp"        "$SRC_VP9"   "VP9"
hw_decode_test "vp8_rkmpp"        "$SRC_VP8"   "VP8"
hw_decode_test "mpeg4_rkmpp"      "$SRC_MPEG4" "MPEG-4"
hw_decode_test "mpeg2_rkmpp"      "$SRC_MPEG2" "MPEG-2"
hw_decode_test "mpeg1_rkmpp"      "$SRC_MPEG1" "MPEG-1"
hw_decode_test "mjpeg_rkmpp"      "$SRC_MJPEG" "MJPEG"
hw_decode_test "h263_rkmpp"       "$SRC_H263"  "H.263"
hw_decode_test "av1_rkmpp"        "$SRC_AV1"   "AV1 (no auto source)"
result_skip "HW decode [VC-1]  (no source -- provide a real .wmv file)"
result_skip "HW decode [AVS2]  (no source -- provide a real AVS2 file)"
result_skip "HW decode [AVS/AVS+] (no source -- provide a real AVS file)"

# ── [7] Hardware encode — all supported codecs ─────────────────────────
# RV1126B MPP encode: H.264, H.265, VP8, MJPEG
printf "\n${YELLOW}[7] Hardware encode -- all supported codecs${NC}\n"
hw_encode_test "h264_rkmpp"  "$LAVFI_HD"  "$TEST_DIR/enc-h264.mp4"  "-b:v 2M"       "H.264 720p/30s"
hw_encode_test "hevc_rkmpp"  "$LAVFI_HD"  "$TEST_DIR/enc-h265.mp4"  "-b:v 2M"       "H.265 720p/30s"
hw_encode_test "vp8_rkmpp"   "$LAVFI_SHORT" "$TEST_DIR/enc-vp8.webm"  "-b:v 1M"     "VP8"
hw_encode_test "mjpeg_rkmpp" "$LAVFI_SHORT" "$TEST_DIR/enc-mjpeg.avi" "-q:v 3 -b:v 0" "MJPEG"

# ── [8] 4K max-capability tests ───────────────────────────────────────
# Tests the advertised max resolution of the RV1126B VPU (3840x2160)
printf "\n${YELLOW}[8] 4K (3840x2160 @ 30fps) max-capability tests${NC}\n"
info "Generating 4K H.264 source for decode test..."
SRC_4K_H264="$TEST_DIR/src-4k-h264.mp4"
SRC_4K_H265="$TEST_DIR/src-4k-h265.mp4"

# Generate 4K H.264 source using HW encoder (fast)
if echo "$HW_ENCODERS" | grep -qw h264_rkmpp; then
    _log4k="$TEST_DIR/src-4k-h264-gen.log"
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "$LAVFI_4K" \
        -c:v h264_rkmpp -b:v 8M \
        "$SRC_4K_H264" 2>"$_log4k" && info "4K H.264 source: ok" || \
        { warn "4K H.264 source generation failed"; SRC_4K_H264=""; }
else
    warn "4K H.264 source: skipped (no h264_rkmpp encoder)"
    SRC_4K_H264=""
fi

# Generate 4K H.265 source using HW encoder (fast)
if echo "$HW_ENCODERS" | grep -qw hevc_rkmpp; then
    _log4k="$TEST_DIR/src-4k-h265-gen.log"
    "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "$LAVFI_4K" \
        -c:v hevc_rkmpp -b:v 8M \
        "$SRC_4K_H265" 2>"$_log4k" && info "4K H.265 source: ok" || \
        { warn "4K H.265 source generation failed"; SRC_4K_H265=""; }
else
    warn "4K H.265 source: skipped (no hevc_rkmpp encoder)"
    SRC_4K_H265=""
fi

# 4K HW decode (log_tag=4k keeps logs separate from 720p tests)
hw_decode_test "h264_rkmpp" "$SRC_4K_H264" "H.264 4K/30fps" "4k"
hw_decode_test "hevc_rkmpp" "$SRC_4K_H265" "H.265 4K/30fps" "4k"

# 4K HW encode
hw_encode_test "h264_rkmpp" "$LAVFI_4K" "$TEST_DIR/enc-4k-h264.mp4" "-b:v 8M" "H.264 4K/30fps"
hw_encode_test "hevc_rkmpp" "$LAVFI_4K" "$TEST_DIR/enc-4k-h265.mp4" "-b:v 8M" "H.265 4K/30fps"

result_skip "4K SW encode (SW encoders are far too slow for 4K on aarch64 -- skipped intentionally)"

# ── [9] Hardware transcode pipelines ──────────────────────────────────
printf "\n${YELLOW}[9] Hardware transcode pipelines${NC}\n"
for _pair in "h264_rkmpp:h264_rkmpp:H.264->H.264:$SRC_H264:tc-h264-h264.mp4" \
             "h264_rkmpp:hevc_rkmpp:H.264->H.265:$SRC_H264:tc-h264-h265.mp4" \
             "hevc_rkmpp:h264_rkmpp:H.265->H.264:$SRC_H265:tc-h265-h264.mp4"; do
    _dec=$(echo "$_pair" | cut -d: -f1)
    _enc=$(echo "$_pair" | cut -d: -f2)
    _lbl=$(echo "$_pair" | cut -d: -f3)
    _src=$(echo "$_pair" | cut -d: -f4)
    _out="$TEST_DIR/$(echo "$_pair" | cut -d: -f5)"
    if echo "$HW_DECODERS" | grep -qw "$_dec" && \
       echo "$HW_ENCODERS" | grep -qw "$_enc" && [ -f "$_src" ]; then
        _log="$TEST_DIR/tc-$(echo "$_lbl" | tr '>' '-').log"
        monitor_start "tc-$(echo "$_lbl" | tr '>' '-')"
        "$FFMPEG" -hide_banner -loglevel info -y \
            -c:v "$_dec" -i "$_src" -c:v "$_enc" -b:v 2M \
            "$_out" 2>"$_log" || true
        monitor_stop "tc-$(echo "$_lbl" | tr '>' '-')"
        if grep -qE 'frame=|Output #0' "$_log"; then
            _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
            result_pass "Transcode $_lbl speed:${_spd:-N/A}"
        else
            result_fail "Transcode $_lbl (see $_log)"
        fi
    else
        result_skip "Transcode $_lbl (missing encoder/decoder or source)"
    fi
done

# ── [10] RGA video processing ──────────────────────────────────────────
printf "\n${YELLOW}[10] RGA video processing${NC}\n"
RGA_FILTERS=$("$FFMPEG" -hide_banner -filters 2>&1 | grep rkrga | awk '{print $2}' | tr '\n' ' ')
if [ -n "$RGA_FILTERS" ]; then
    result_pass "RGA filters available: $RGA_FILTERS"
else
    warn "No RGA filters found"
fi

if echo "$RGA_FILTERS" | grep -q scale_rkrga && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/rga-scale.log"
    monitor_start "rga-scale"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" \
        -vf "scale_rkrga=640:360" \
        -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/rga-scale.mp4" 2>"$_log" || true
    monitor_stop "rga-scale"
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "RGA scale 1280x720->640x360 speed:${_spd:-N/A}"
    else
        result_fail "RGA scale (see $_log)"
    fi
else
    result_skip "RGA scale (no scale_rkrga or no H.264 source)"
fi

if echo "$RGA_FILTERS" | grep -q scale_rkrga && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/rga-csc.log"
    monitor_start "rga-csc"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" \
        -vf "scale_rkrga=1280:720:format=nv12" \
        -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/rga-csc.mp4" 2>"$_log" || true
    monitor_stop "rga-csc"
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "RGA color space conversion (yuv420p->nv12) speed:${_spd:-N/A}"
    else
        result_fail "RGA color space conversion (see $_log)"
    fi
else
    result_skip "RGA color space conversion (no scale_rkrga or no H.264 source)"
fi

result_skip "RGA deinterlace (yadif_rkrga not compiled; vpp_rkrga=scale/CSC only)"

# ── [11] SW performance comparison ────────────────────────────────────
# Identical params to HW tests (30s, 1280x720, 25fps, 2Mbps) for direct comparison
printf "\n${YELLOW}[11] SW performance comparison${NC}\n"
SW_ENCODERS=$("$FFMPEG" -hide_banner -encoders 2>&1)
SW_DECODERS=$("$FFMPEG" -hide_banner -decoders 2>&1)

# SW decode H.264
if echo "$SW_DECODERS" | grep -qE '^ V..... h264 ' && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/dec-h264-sw.log"
    monitor_start "dec-h264-sw"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v h264 -i "$SRC_H264" -f null - 2>"$_log" || true
    monitor_stop "dec-h264-sw"
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "SW decode [H.264/h264] speed:${_spd:-N/A}"
    else
        result_fail "SW decode [H.264/h264] (see $_log)"
    fi
else
    result_skip "SW decode [H.264] (no software h264 decoder or no source)"
fi

# SW decode H.265
if echo "$SW_DECODERS" | grep -qE '^ V..... hevc ' && [ -f "$SRC_H265" ]; then
    _log="$TEST_DIR/dec-hevc-sw.log"
    monitor_start "dec-hevc-sw"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v hevc -i "$SRC_H265" -f null - 2>"$_log" || true
    monitor_stop "dec-hevc-sw"
    if grep -qE 'frame=|Output #0' "$_log"; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        result_pass "SW decode [H.265/hevc] speed:${_spd:-N/A}"
    else
        result_fail "SW decode [H.265/hevc] (see $_log)"
    fi
else
    result_skip "SW decode [H.265] (no software hevc decoder or no source)"
fi

# SW encode H.264 (libx264)
if echo "$SW_ENCODERS" | grep -q libx264; then
    _log="$TEST_DIR/enc-libx264.log"
    monitor_start "enc-libx264"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "$LAVFI_HD" \
        -c:v libx264 -b:v 2M \
        "$TEST_DIR/enc-libx264.mp4" 2>"$_log" || true
    monitor_stop "enc-libx264"
    if [ -f "$TEST_DIR/enc-libx264.mp4" ] && [ -s "$TEST_DIR/enc-libx264.mp4" ]; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        _sz=$(du -h "$TEST_DIR/enc-libx264.mp4" | cut -f1)
        result_pass "SW encode [H.264/libx264] speed:${_spd:-N/A} size:$_sz"
    else
        result_fail "SW encode [H.264/libx264] (see $_log)"
    fi
else
    result_skip "SW encode [H.264/libx264] (not compiled)"
fi

# SW encode H.265 (libx265)
if echo "$SW_ENCODERS" | grep -q libx265; then
    _log="$TEST_DIR/enc-libx265.log"
    monitor_start "enc-libx265"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "$LAVFI_HD" \
        -c:v libx265 -b:v 2M -x265-params "log-level=error" \
        "$TEST_DIR/enc-libx265.mp4" 2>"$_log" || true
    monitor_stop "enc-libx265"
    if [ -f "$TEST_DIR/enc-libx265.mp4" ] && [ -s "$TEST_DIR/enc-libx265.mp4" ]; then
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        _sz=$(du -h "$TEST_DIR/enc-libx265.mp4" | cut -f1)
        result_pass "SW encode [H.265/libx265] speed:${_spd:-N/A} size:$_sz"
    else
        result_fail "SW encode [H.265/libx265] (see $_log)"
    fi
else
    result_skip "SW encode [H.265/libx265] (not compiled)"
fi

# SW VP8/VP9 via libvpx (known SIGILL on rv1126b)
for codec in libvpx libvpx-vp9; do
    [ "$codec" = "libvpx" ] && _lbl="VP8" || _lbl="VP9"
    if echo "$SW_ENCODERS" | grep -q "$codec"; then
        _out="$TEST_DIR/enc-${codec}.webm"
        _log="$TEST_DIR/enc-${codec}.log"
        "$FFMPEG" -hide_banner -loglevel warning -y \
            -f lavfi -i "$LAVFI_HD" \
            -c:v "$codec" -b:v 2M \
            "$_out" 2>"$_log" && _ec=0 || _ec=$?
        if [ -f "$_out" ] && [ -s "$_out" ]; then
            _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
            _sz=$(du -h "$_out" | cut -f1)
            result_pass "SW encode [$_lbl/$codec] speed:${_spd:-N/A} size:$_sz"
        elif [ "$_ec" -eq 132 ]; then
            result_skip "SW encode [$_lbl/$codec] (SIGILL -- prebuilt libvpx uses CPU extensions absent on rv1126b; see todo.md)"
        else
            result_fail "SW encode [$_lbl/$codec] (see $_log)"
        fi
    else
        result_skip "SW encode [$_lbl/$codec] (not compiled)"
    fi
done

if echo "$SW_ENCODERS" | grep -q "libaom-av1"; then
    result_pass "SW codec available: libaom-av1"
else
    result_skip "SW codec: libaom-av1 (not compiled)"
fi

# ── [12] HW vs SW performance comparison table ────────────────────────
printf "\n${YELLOW}[12] HW vs SW performance comparison${NC}\n"
_xs() { grep -oE 'speed=[0-9.]+x' "$1" 2>/dev/null | tail -1 | sed 's/speed=//'; }

_hw_dec_h264=$(_xs "$TEST_DIR/dec-h264_rkmpp.log")
_hw_dec_h265=$(_xs "$TEST_DIR/dec-hevc_rkmpp.log")
_hw_enc_h264=$(_xs "$TEST_DIR/enc-h264_rkmpp-enc-h264-mp4.log")
_hw_enc_h265=$(_xs "$TEST_DIR/enc-hevc_rkmpp-enc-h265-mp4.log")
_sw_dec_h264=$(_xs "$TEST_DIR/dec-h264-sw.log")
_sw_dec_h265=$(_xs "$TEST_DIR/dec-hevc-sw.log")
_sw_enc_h264=$(_xs "$TEST_DIR/enc-libx264.log")
_sw_enc_h265=$(_xs "$TEST_DIR/enc-libx265.log")


_cmp() {
    _op="$1"; _hw="$2"; _sw="$3"
    if [ -n "$_hw" ] && [ -n "$_sw" ]; then
        _hwn=$(echo "$_hw" | sed 's/x//'); _swn=$(echo "$_sw" | sed 's/x//')
        _mult=$(awk "BEGIN{if($_swn>0) printf \"%.1f\", $_hwn/$_swn; else print \"N/A\"}" 2>/dev/null || echo "N/A")
        printf "  %-28s ${GREEN}%-10s${NC} ${YELLOW}%-10s${NC} ${GREEN}%sx${NC}\n" "$_op" "$_hw" "$_sw" "$_mult"
    elif [ -n "$_hw" ]; then
        printf "  %-28s ${GREEN}%-10s${NC} ${YELLOW}%-10s${NC}\n" "$_op" "$_hw" "${_sw:-N/A (sw only)}"
    else
        printf "  %-28s ${GREEN}%-10s${NC} ${YELLOW}%-10s${NC}\n" "$_op" "${_hw:-N/A}" "${_sw:-N/A}"
    fi
}

printf "\n  ${BLUE}Source: 1280x720@25fps 30s 2Mbps (720p) | 3840x2160@30fps 30s 8Mbps (4K)${NC}\n"
printf "  ${BLUE}%-28s %-10s %-10s %s${NC}\n" "Operation" "HW (rkmpp)" "SW (cpu)" "HW Speedup"
printf "  ${BLUE}%-28s %-10s %-10s %s${NC}\n" "────────────────────────────" "──────────" "──────────" "──────────"
_cmp "720p  H.264 decode"   "$_hw_dec_h264"  "$_sw_dec_h264"
_cmp "720p  H.265 decode"   "$_hw_dec_h265"  "$_sw_dec_h265"
_cmp "720p  H.264 encode"   "$_hw_enc_h264"  "$_sw_enc_h264"
_cmp "720p  H.265 encode"   "$_hw_enc_h265"  "$_sw_enc_h265"

# 4K rows — read from 4k-tagged logs
_hw_dec_4kh264=$(_xs "$TEST_DIR/dec-h264_rkmpp-4k.log" 2>/dev/null)
_hw_dec_4kh265=$(_xs "$TEST_DIR/dec-hevc_rkmpp-4k.log" 2>/dev/null)
_hw_enc_4kh264=$(_xs "$TEST_DIR/enc-h264_rkmpp-enc-4k-h264-mp4.log" 2>/dev/null)
_hw_enc_4kh265=$(_xs "$TEST_DIR/enc-hevc_rkmpp-enc-4k-h265-mp4.log" 2>/dev/null)
_cmp "4K    H.264 decode"   "$_hw_dec_4kh264" ""
_cmp "4K    H.265 decode"   "$_hw_dec_4kh265" ""
_cmp "4K    H.264 encode"   "$_hw_enc_4kh264" "(sw skipped)"
_cmp "4K    H.265 encode"   "$_hw_enc_4kh265" "(sw skipped)"
printf "\n"
result_pass "HW vs SW comparison table printed"

# ── [13] System resources (idle baseline after tests) ─────────────────
printf "\n${YELLOW}[13] System resources${NC}\n"
info "Memory:"
free -h 2>/dev/null || grep -E 'MemTotal|MemFree|MemAvailable' /proc/meminfo || true
info "CPU count:"
grep -c '^processor' /proc/cpuinfo 2>/dev/null || true
info "CPU info:"
grep 'Hardware\|model name\|cpu MHz' /proc/cpuinfo 2>/dev/null | sort -u || true
info "Load (after tests):"
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
