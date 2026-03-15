#!/bin/sh
#
# test-on-device.sh
# FFmpeg-Rockchip hardware & software codec test suite for RV1126B-P
#
# Usage (from host PC):
#   sh scripts/test-on-device.sh <DEVICE_IP>
#   DEVICE_IP=192.168.1.95 sh scripts/test-on-device.sh
#
# Usage (directly on device):
#   sh test-on-device.sh
#
# Test sources are cached in /userdata/ffmpeg-test-sources/ (persistent
# across reboots). Only missing sources are generated on first run.
#
# Estimated runtime:
#   First run  (source generation + tests): ~20 minutes
#   Cached run (sources already present):   ~15 minutes
#
# For accurate results, stop RKIPC first — it consumes ~85% of VEPU:
#   /etc/init.d/S99rkipc stop

set -e

# ── Remote dispatch ───────────────────────────────────────────────────
# When called from a non-aarch64 host with a device IP, copy this script
# to the device and run it over SSH.
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

# ── Colours & helpers ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; NC='\033[0m'

info()    { printf "${BLUE}[+]${NC} %s\n" "$*"; }
success() { printf "${GREEN}[✓]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[!]${NC} %s\n" "$*"; }
error()   { printf "${RED}[✗]${NC} %s\n" "$*"; exit 1; }
skip()    { printf "${YELLOW}[-]${NC} %s\n" "$*"; }

# ── Directories ───────────────────────────────────────────────────────
SOURCE_DIR="/userdata/ffmpeg-test-sources"   # persistent across reboots
TEST_DIR="/tmp/ffmpeg-rv1126b-test"          # ephemeral test outputs
RESULTS_FILE="$TEST_DIR/test-results.txt"

PASS=0; FAIL=0; SKIP=0
result_pass() { PASS=$((PASS+1)); success "$1"; echo "PASS: $1" >> "$RESULTS_FILE"; }
result_fail() { FAIL=$((FAIL+1)); printf "${RED}[✗]${NC} %s\n" "$1"; echo "FAIL: $1" >> "$RESULTS_FILE"; }
result_skip() { SKIP=$((SKIP+1)); skip   "$1"; echo "SKIP: $1" >> "$RESULTS_FILE"; }

# ── Auto-detect ffmpeg binary ─────────────────────────────────────────
find_ffmpeg() {
    for c in \
        /usr/local/ffmpeg-rv1126b/bin/ffmpeg-rv1126b \
        /usr/local/ffmpeg-rv1126b/bin/ffmpeg \
        /usr/local/bin/ffmpeg \
        /usr/bin/ffmpeg \
        ffmpeg
    do
        if command -v "$c" >/dev/null 2>&1 || [ -x "$c" ]; then
            echo "$c"; return 0
        fi
    done
    return 1
}

FFMPEG=$(find_ffmpeg) || error "ffmpeg not found. Run install-ffmpeg-rv1126b.sh first."

mkdir -p "$SOURCE_DIR" "$TEST_DIR"
: > "$RESULTS_FILE"

# ── Enable VPU load monitoring ────────────────────────────────────────
VPU_MON=0
if [ -w /proc/mpp_service/load_interval ]; then
    echo 1000 > /proc/mpp_service/load_interval
    VPU_MON=1
fi

cleanup() {
    for _pf in "$TEST_DIR"/mon-*.pid; do
        [ -f "$_pf" ] && kill "$(cat "$_pf")" 2>/dev/null || true
        rm -f "$_pf"
    done
    [ "$VPU_MON" = "1" ] && echo 0 > /proc/mpp_service/load_interval 2>/dev/null || true
}
trap cleanup EXIT

# ── Resource monitor (CPU + RAM + VPU) ────────────────────────────────
# Background sampler at ~1s interval; records CPU, RAM, RKVENC and
# RKVDEC utilisation to a log file.  Parsed by monitor_stop().
monitor_start() {
    _mn="$1"; _mlog="$TEST_DIR/mon-${_mn}.log"; : > "$_mlog"
    (
        while true; do
            awk '/^cpu /{t=$2+$3+$4+$5+$6+$7+$8+$9;b=t-$5-$6;printf "CPU %d %d\n",t,b}' /proc/stat
            awk '/^MemTotal:/{t=$2}/^MemAvailable:/{a=$2}END{printf "MEM %d %d\n",t,a}' /proc/meminfo
            if [ -f /proc/mpp_service/load ]; then
                awk '/rkvenc/{n=NF;gsub(/%/,"",$n);printf "VPU_ENC %s\n",$n}
                     /rkvdec/{n=NF;gsub(/%/,"",$n);printf "VPU_DEC %s\n",$n}' /proc/mpp_service/load
            fi
            sleep 1
        done
    ) >> "$_mlog" 2>/dev/null &
    echo $! > "$TEST_DIR/mon-${_mn}.pid"
}

# Stop sampler, parse log, return a compact resource summary line.
# Caller should capture via $(): _res=$(monitor_stop "tag")
monitor_stop() {
    _mn="$1"; _pidf="$TEST_DIR/mon-${_mn}.pid"; _mlog="$TEST_DIR/mon-${_mn}.log"
    [ -f "$_pidf" ] && { kill "$(cat "$_pidf")" 2>/dev/null || true; rm -f "$_pidf"; }
    [ -f "$_mlog" ] && [ -s "$_mlog" ] && awk '
        /^CPU/{if(pt>0){dt=$2-pt;db=$3-pb;if(dt>0)p=db*100/dt;if(p>mc)mc=p;sc+=p;cc++}pt=$2;pb=$3}
        /^MEM/{u=($2-$3)/1024;if(u>mm)mm=u}
        /^VPU_ENC/{v=$2+0;if(v>me)me=v;se+=v;ce++}
        /^VPU_DEC/{v=$2+0;if(v>md)md=v;sd+=v;cd++}
        END{
            ac=(cc>0)?sc/cc:0; ae=(ce>0)?se/ce:0; ad=(cd>0)?sd/cd:0
            printf "       CPU: peak %d%% avg %d%%  |  RAM: peak %d MiB  |  VEPU: peak %.0f%% avg %.0f%%  VDPU: peak %.0f%% avg %.0f%%\n",mc,ac,mm,me,ae,md,ad
        }' "$_mlog"
}

# ── Codec test helpers ────────────────────────────────────────────────
# hw_decode_test <decoder> <input_file> <label> [log_tag]
hw_decode_test() {
    _dc="$1"; _in="$2"; _lbl="${3:-$1}"; _tag="${4:-}"
    if ! echo "$HW_DECODERS" | grep -qw "$_dc"; then
        result_skip "HW decode [$_lbl] (not compiled)"; return
    fi
    if [ ! -f "$_in" ]; then
        result_skip "HW decode [$_lbl] (no source)"; return
    fi
    _logkey="dec-${_dc}${_tag:+-$_tag}"
    _log="$TEST_DIR/${_logkey}.log"
    monitor_start "$_logkey"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v "$_dc" -i "$_in" -f null - 2>"$_log" || true
    _res=$(monitor_stop "$_logkey")
    # Print test result FIRST, then resource usage
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if grep -qE 'frame=|Output #0' "$_log"; then
        result_pass "HW decode [$_lbl] speed:${_spd:-N/A}"
    elif grep -q 'unsupported' "$_log"; then
        result_skip "HW decode [$_lbl] (MPP unsupported on this SoC)"
    else
        result_fail "HW decode [$_lbl] (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
}

# hw_encode_test <encoder> <lavfi_src> <output_file> <extra_args> <label>
hw_encode_test() {
    _ec="$1"; _src="$2"; _out="$3"; _extra="$4"; _lbl="${5:-$1}"
    if ! echo "$HW_ENCODERS" | grep -qw "$_ec"; then
        result_skip "HW encode [$_lbl] (not compiled)"; return
    fi
    _logkey="enc-${_ec}-$(basename "$_out" | sed 's/[^a-z0-9]/-/g')"
    _log="$TEST_DIR/${_logkey}.log"
    monitor_start "$_logkey"
    # shellcheck disable=SC2086
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "$_src" \
        -c:v "$_ec" $_extra \
        "$_out" 2>"$_log" || true
    _res=$(monitor_stop "$_logkey")
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if [ -f "$_out" ] && [ -s "$_out" ]; then
        _sz=$(du -h "$_out" | cut -f1)
        result_pass "HW encode [$_lbl] speed:${_spd:-N/A} size:$_sz"
    else
        result_fail "HW encode [$_lbl] (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
}


# ══════════════════════════════════════════════════════════════════════
#  BANNER
# ══════════════════════════════════════════════════════════════════════
printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BLUE}  FFmpeg-Rockchip Test Suite — RV1126B-P${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n\n"

printf "  %-17s %s\n" "Date:" "$(date)"
printf "  %-17s %s\n" "FFmpeg:" "$FFMPEG"
printf "  %-17s %s\n" "Source cache:" "$SOURCE_DIR"
printf "  %-17s %s\n" "Test output:" "$TEST_DIR"
printf "  %-17s %s\n" "Report:" "$RESULTS_FILE"

# ── VPU Hardware ──────────────────────────────────────────────────────
printf "\n${BLUE}── VPU Hardware ──${NC}\n"
if [ -f /proc/mpp_service/supports-device ]; then
    grep 'DEVICE' /proc/mpp_service/supports-device | sed 's/^/  /'
fi
if [ -f /proc/mpp_service/version ]; then
    printf "  MPP kernel:      %s\n" "$(cat /proc/mpp_service/version)"
fi

# VPU clock frequencies (procfs first line: "name freqHz")
_read_vpu_clk() {
    _f="/proc/mpp_service/$1/$2"
    [ -f "$_f" ] && head -1 "$_f" 2>/dev/null | awk '{gsub(/Hz/,"",$2); if($2+0>0) printf "%d MHz",$2/1000000}'
}
_enc_aclk=$(_read_vpu_clk rkvenc0 aclk)
_enc_core=$(_read_vpu_clk rkvenc0 clk_core)
_dec_aclk=$(_read_vpu_clk rkvdec0 aclk)
_dec_core=$(_read_vpu_clk rkvdec0 clk_core)
[ -n "$_enc_core" ] && printf "  RKVENC (VEPU):   core %s, AXI %s\n" "$_enc_core" "${_enc_aclk:-?}"
[ -n "$_dec_aclk" ] && printf "  RKVDEC (VDPU):   AXI %s%s\n" "$_dec_aclk" "${_dec_core:+, core $_dec_core}"
printf "  VPU monitoring:  %s\n" "$([ "$VPU_MON" = 1 ] && echo 'enabled (1s sample interval)' || echo 'disabled')"

# ── RKIPC contention check ───────────────────────────────────────────
if pgrep -x rkipc >/dev/null 2>&1; then
    printf "\n  ${RED}⚠  WARNING: RKIPC is running and consuming ~85%% of VEPU!${NC}\n"
    printf "  ${RED}   Encode/transcode results will NOT be accurate.${NC}\n"
    printf "  ${RED}   Stop it first:  /etc/init.d/S99rkipc stop${NC}\n"
fi

# ── HW codecs ─────────────────────────────────────────────────────────
printf "\n${BLUE}── HW Codecs ──${NC}\n"
HW_DECODERS=$("$FFMPEG" -hide_banner -decoders 2>&1 | grep _rkmpp | awk '{print $2}' | tr '\n' ' ')
HW_ENCODERS=$("$FFMPEG" -hide_banner -encoders 2>&1 | grep _rkmpp | awk '{print $2}' | tr '\n' ' ')
printf "  Decoders: %s\n" "${HW_DECODERS:-none}"
printf "  Encoders: %s\n" "${HW_ENCODERS:-none}"
printf "  Note:     VP8/VP9 HW decode supported but untested (no encoder to generate sources)\n"

# ── Estimated runtime ─────────────────────────────────────────────────
_cached=0
for _f in source-h264.mp4 source-h265.mp4 source-mjpeg.avi source-4k-h264.mp4 source-4k-h265.mp4; do
    [ -f "$SOURCE_DIR/$_f" ] && _cached=$((_cached + 1))
done
if [ "$_cached" -ge 5 ]; then
    printf "\n  ${GREEN}All 5 test sources cached — estimated runtime: ~15 minutes${NC}\n"
else
    printf "\n  ${YELLOW}Source generation needed (%d/5 cached) — estimated runtime: ~20 minutes${NC}\n" "$_cached"
fi

# Results file header
{ printf "FFmpeg-Rockchip Test Results — %s\n" "$(date)"
  printf "Binary: %s\n" "$FFMPEG"
  printf "HW Decoders: %s\n" "$HW_DECODERS"
  printf "HW Encoders: %s\n" "$HW_ENCODERS"
  printf "======================================\n\n"
} >> "$RESULTS_FILE"

# ══════════════════════════════════════════════════════════════════════
# [1/10] PRE-FLIGHT CHECKS
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[1/10] Pre-flight — FFmpeg version, device nodes, HW codec detection${NC}\n"

if "$FFMPEG" -version 2>&1 | head -1 | grep -q ffmpeg; then
    "$FFMPEG" -version 2>&1 | head -1
    result_pass "FFmpeg version check"
else
    result_fail "FFmpeg version check"
fi

for dev in /dev/mpp_service /dev/rga; do
    [ -e "$dev" ] && result_pass "Device node: $dev" || warn "Missing: $dev"
done

[ -n "$HW_DECODERS" ] && result_pass "MPP decoders: $HW_DECODERS" || result_fail "No MPP decoders"
[ -n "$HW_ENCODERS" ] && result_pass "MPP encoders: $HW_ENCODERS" || warn "No MPP encoders"

# ══════════════════════════════════════════════════════════════════════
# [2/10] TEST SOURCE PREPARATION
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[2/10] Source preparation — cached in %s (persistent across reboots)${NC}\n" "$SOURCE_DIR"

LAVFI_720="testsrc=duration=30:size=1280x720:rate=25,format=yuv420p"
LAVFI_MJPEG="testsrc=duration=10:size=1280x720:rate=25,format=yuv420p"
LAVFI_4K="testsrc=duration=30:size=3840x2160:rate=30,format=yuv420p"

SRC_H264="$SOURCE_DIR/source-h264.mp4"
SRC_H265="$SOURCE_DIR/source-h265.mp4"
SRC_MJPEG="$SOURCE_DIR/source-mjpeg.avi"
SRC_4K_H264="$SOURCE_DIR/source-4k-h264.mp4"
SRC_4K_H265="$SOURCE_DIR/source-4k-h265.mp4"

# Helper: generate a source only if not already cached
_gen() {
    _out="$1"; _label="$2"; shift 2
    if [ -f "$_out" ] && [ -s "$_out" ]; then
        info "$_label: cached ($(du -h "$_out" | cut -f1))"
        return 0
    fi
    info "$_label: generating..."
    if "$FFMPEG" -hide_banner -loglevel error -y "$@" "$_out" 2>/dev/null; then
        success "$_label: ok ($(du -h "$_out" | cut -f1))"
    else
        warn "$_label: FAILED"
        rm -f "$_out"
        return 1
    fi
}

# H.264 720p 30s — libx264 (always available)
_gen "$SRC_H264" "H.264 720p 30s" \
    -f lavfi -i "$LAVFI_720" -c:v libx264 -pix_fmt yuv420p -b:v 2M || true

# H.265 720p 30s — prefer HW encoder, fallback to libx265
if [ -f "$SRC_H265" ] && [ -s "$SRC_H265" ]; then
    info "H.265 720p 30s: cached ($(du -h "$SRC_H265" | cut -f1))"
else
    info "H.265 720p 30s: generating..."
    if "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "$LAVFI_720" -c:v hevc_rkmpp -b:v 2M "$SRC_H265" 2>/dev/null; then
        success "H.265 720p 30s: ok ($(du -h "$SRC_H265" | cut -f1)) [HW]"
    elif "$FFMPEG" -hide_banner -loglevel error -y \
        -f lavfi -i "$LAVFI_720" -c:v libx265 -b:v 2M \
        -x265-params "log-level=error" "$SRC_H265" 2>/dev/null; then
        success "H.265 720p 30s: ok ($(du -h "$SRC_H265" | cut -f1)) [libx265]"
    else
        warn "H.265 720p 30s: FAILED"
        rm -f "$SRC_H265"
    fi
fi

# MJPEG 720p 10s
_gen "$SRC_MJPEG" "MJPEG 720p 10s" \
    -f lavfi -i "$LAVFI_MJPEG" -c:v mjpeg -q:v 3 || true

# 4K H.264 30s — HW encoder only (SW too slow for 4K)
if echo "$HW_ENCODERS" | grep -qw h264_rkmpp; then
    _gen "$SRC_4K_H264" "4K H.264 30s" \
        -f lavfi -i "$LAVFI_4K" -c:v h264_rkmpp -b:v 8M || true
else
    warn "4K H.264 source: skipped (no h264_rkmpp encoder)"
fi

# 4K H.265 30s — HW encoder only
if echo "$HW_ENCODERS" | grep -qw hevc_rkmpp; then
    _gen "$SRC_4K_H265" "4K H.265 30s" \
        -f lavfi -i "$LAVFI_4K" -c:v hevc_rkmpp -b:v 8M || true
else
    warn "4K H.265 source: skipped (no hevc_rkmpp encoder)"
fi

# Summary
_total=0; _ok=0
for _f in "$SRC_H264" "$SRC_H265" "$SRC_MJPEG" "$SRC_4K_H264" "$SRC_4K_H265"; do
    _total=$((_total + 1))
    [ -f "$_f" ] && [ -s "$_f" ] && _ok=$((_ok + 1))
done
result_pass "Source preparation: $_ok/$_total sources ready"

# ══════════════════════════════════════════════════════════════════════
# [3/10] HW DECODE — 720p
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[3/10] HW Decode 720p — H.264, H.265, MJPEG via VDPU (30s 1280x720@25fps 2Mbps)${NC}\n"

hw_decode_test "h264_rkmpp"  "$SRC_H264"  "H.264 720p"
hw_decode_test "hevc_rkmpp"  "$SRC_H265"  "H.265 720p"
hw_decode_test "mjpeg_rkmpp" "$SRC_MJPEG" "MJPEG 720p"

# ══════════════════════════════════════════════════════════════════════
# [4/10] HW ENCODE — 720p
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[4/10] HW Encode 720p — H.264, H.265, MJPEG via VEPU (30s 1280x720@25fps 2Mbps)${NC}\n"

hw_encode_test "h264_rkmpp"  "$LAVFI_720"   "$TEST_DIR/enc-h264.mp4"  "-b:v 2M"         "H.264 720p"
hw_encode_test "hevc_rkmpp"  "$LAVFI_720"   "$TEST_DIR/enc-h265.mp4"  "-b:v 2M"         "H.265 720p"
hw_encode_test "mjpeg_rkmpp" "$LAVFI_MJPEG" "$TEST_DIR/enc-mjpeg.avi" "-q:v 3 -b:v 0"   "MJPEG 720p"

# ══════════════════════════════════════════════════════════════════════
# [5/10] 4K MAX-CAPABILITY
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[5/10] 4K capability — H.264/H.265 decode + encode (30s 3840x2160@30fps 8Mbps)${NC}\n"
info "Note: 4K through FFmpeg is CPU-limited (~0.4x realtime). The VDPU hardware has"
info "      headroom (~25% load) but FFmpeg's single-threaded pipeline on Cortex-A7"
info "      cannot feed/drain 4K frames fast enough. RKIPC achieves 4K@30fps via DVBM"
info "      zero-copy, bypassing CPU frame handling entirely."

hw_decode_test "h264_rkmpp" "$SRC_4K_H264" "H.264 4K" "4k"
hw_decode_test "hevc_rkmpp" "$SRC_4K_H265" "H.265 4K" "4k"
hw_encode_test "h264_rkmpp" "$LAVFI_4K" "$TEST_DIR/enc-4k-h264.mp4" "-b:v 8M" "H.264 4K"
hw_encode_test "hevc_rkmpp" "$LAVFI_4K" "$TEST_DIR/enc-4k-h265.mp4" "-b:v 8M" "H.265 4K"

# ══════════════════════════════════════════════════════════════════════
# [6/10] HW TRANSCODE
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[6/10] HW Transcode — decode+encode pipelines (30s 720p, H.264 <-> H.265)${NC}\n"

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
        _logkey="tc-$(echo "$_lbl" | tr '>' '-')"
        _log="$TEST_DIR/${_logkey}.log"
        monitor_start "$_logkey"
        "$FFMPEG" -hide_banner -loglevel info -y \
            -c:v "$_dec" -i "$_src" -c:v "$_enc" -b:v 2M \
            "$_out" 2>"$_log" || true
        _res=$(monitor_stop "$_logkey")
        _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
        if grep -qE 'frame=|Output #0' "$_log"; then
            result_pass "Transcode $_lbl speed:${_spd:-N/A}"
        else
            result_fail "Transcode $_lbl (see $_log)"
        fi
        [ -n "$_res" ] && printf "%s\n" "$_res"
    else
        result_skip "Transcode $_lbl (missing encoder/decoder or source)"
    fi
done

# ══════════════════════════════════════════════════════════════════════
# [7/10] RGA VIDEO PROCESSING
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[7/10] RGA processing — hardware scale + colour-space conversion via RGA2${NC}\n"

RGA_FILTERS=$("$FFMPEG" -hide_banner -filters 2>&1 | grep rkrga | awk '{print $2}' | tr '\n' ' ')
[ -n "$RGA_FILTERS" ] && result_pass "RGA filters: $RGA_FILTERS" || warn "No RGA filters"

# Scale 1280x720 -> 640x360
if echo "$RGA_FILTERS" | grep -q scale_rkrga && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/rga-scale.log"
    monitor_start "rga-scale"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" \
        -vf "scale_rkrga=640:360" \
        -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/rga-scale.mp4" 2>"$_log" || true
    _res=$(monitor_stop "rga-scale")
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if [ -f "$TEST_DIR/rga-scale.mp4" ] && [ -s "$TEST_DIR/rga-scale.mp4" ]; then
        result_pass "RGA scale 1280x720->640x360 speed:${_spd:-N/A}"
    elif grep -q 'Impossible to convert' "$_log"; then
        result_skip "RGA scale (DRM_PRIME format negotiation not supported in this build)"
    else
        result_fail "RGA scale (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
else
    result_skip "RGA scale (no scale_rkrga or no source)"
fi

# Colour space conversion yuv420p -> nv12
if echo "$RGA_FILTERS" | grep -q scale_rkrga && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/rga-csc.log"
    monitor_start "rga-csc"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -c:v h264_rkmpp -i "$SRC_H264" \
        -vf "scale_rkrga=1280:720:format=nv12" \
        -c:v h264_rkmpp -b:v 1M \
        "$TEST_DIR/rga-csc.mp4" 2>"$_log" || true
    _res=$(monitor_stop "rga-csc")
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if [ -f "$TEST_DIR/rga-csc.mp4" ] && [ -s "$TEST_DIR/rga-csc.mp4" ]; then
        result_pass "RGA CSC yuv420p->nv12 speed:${_spd:-N/A}"
    elif grep -q 'Impossible to convert' "$_log"; then
        result_skip "RGA CSC (DRM_PRIME format negotiation not supported in this build)"
    else
        result_fail "RGA CSC (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
else
    result_skip "RGA CSC (no scale_rkrga or no source)"
fi

# ══════════════════════════════════════════════════════════════════════
# [8/10] SW PERFORMANCE COMPARISON
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[8/10] SW comparison — CPU-only decode/encode for HW speedup reference (30s 720p)${NC}\n"
info "Identical parameters to HW tests (1280x720@25fps 2Mbps) for direct comparison."

SW_ENCODERS=$("$FFMPEG" -hide_banner -encoders 2>&1)
SW_DECODERS=$("$FFMPEG" -hide_banner -decoders 2>&1)

# SW decode H.264
if echo "$SW_DECODERS" | grep -qE '^ V..... h264 ' && [ -f "$SRC_H264" ]; then
    _log="$TEST_DIR/dec-h264-sw.log"
    monitor_start "dec-h264-sw"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v h264 -i "$SRC_H264" -f null - 2>"$_log" || true
    _res=$(monitor_stop "dec-h264-sw")
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if grep -qE 'frame=|Output #0' "$_log"; then
        result_pass "SW decode [H.264] speed:${_spd:-N/A}"
    else
        result_fail "SW decode [H.264] (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
else
    result_skip "SW decode [H.264] (no decoder or no source)"
fi

# SW decode H.265
if echo "$SW_DECODERS" | grep -qE '^ V..... hevc ' && [ -f "$SRC_H265" ]; then
    _log="$TEST_DIR/dec-hevc-sw.log"
    monitor_start "dec-hevc-sw"
    "$FFMPEG" -hide_banner -loglevel info \
        -c:v hevc -i "$SRC_H265" -f null - 2>"$_log" || true
    _res=$(monitor_stop "dec-hevc-sw")
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if grep -qE 'frame=|Output #0' "$_log"; then
        result_pass "SW decode [H.265] speed:${_spd:-N/A}"
    else
        result_fail "SW decode [H.265] (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
else
    result_skip "SW decode [H.265] (no decoder or no source)"
fi

# SW encode H.264 (libx264)
if echo "$SW_ENCODERS" | grep -q libx264; then
    _log="$TEST_DIR/enc-libx264.log"
    monitor_start "enc-libx264"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "$LAVFI_720" \
        -c:v libx264 -b:v 2M \
        "$TEST_DIR/enc-libx264.mp4" 2>"$_log" || true
    _res=$(monitor_stop "enc-libx264")
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if [ -f "$TEST_DIR/enc-libx264.mp4" ] && [ -s "$TEST_DIR/enc-libx264.mp4" ]; then
        _sz=$(du -h "$TEST_DIR/enc-libx264.mp4" | cut -f1)
        result_pass "SW encode [libx264] speed:${_spd:-N/A} size:$_sz"
    else
        result_fail "SW encode [libx264] (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
else
    result_skip "SW encode [libx264] (not compiled)"
fi

# SW encode H.265 (libx265)
if echo "$SW_ENCODERS" | grep -q libx265; then
    _log="$TEST_DIR/enc-libx265.log"
    monitor_start "enc-libx265"
    "$FFMPEG" -hide_banner -loglevel info -y \
        -f lavfi -i "$LAVFI_720" \
        -c:v libx265 -b:v 2M -x265-params "log-level=error" \
        "$TEST_DIR/enc-libx265.mp4" 2>"$_log" || true
    _res=$(monitor_stop "enc-libx265")
    _spd=$(grep -oE 'speed=[0-9.]+x' "$_log" | tail -1 | sed 's/speed=//')
    if [ -f "$TEST_DIR/enc-libx265.mp4" ] && [ -s "$TEST_DIR/enc-libx265.mp4" ]; then
        _sz=$(du -h "$TEST_DIR/enc-libx265.mp4" | cut -f1)
        result_pass "SW encode [libx265] speed:${_spd:-N/A} size:$_sz"
    else
        result_fail "SW encode [libx265] (see $_log)"
    fi
    [ -n "$_res" ] && printf "%s\n" "$_res"
else
    result_skip "SW encode [libx265] (not compiled)"
fi

# ══════════════════════════════════════════════════════════════════════
# [9/10] HW vs SW COMPARISON TABLE
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[9/10] Performance summary — HW vs SW comparison table${NC}\n"

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
    _mult="N/A"
    case "$_sw" in
        [0-9]*)
            _hwn=$(echo "$_hw" | sed 's/x//'); _swn=$(echo "$_sw" | sed 's/x//')
            _mult=$(awk "BEGIN{if($_swn>0) printf \"%.1fx\", $_hwn/$_swn; else print \"N/A\"}" 2>/dev/null || echo "N/A")
            ;;
    esac
    printf "  %-28s ${GREEN}%-10s${NC} ${YELLOW}%-10s${NC} ${GREEN}%-10s${NC}\n" \
        "$_op" "${_hw:-N/A}" "${_sw:-N/A}" "$_mult"
}

printf "\n  ${BLUE}Source: 1280x720@25fps 30s 2Mbps (720p) | 3840x2160@30fps 30s 8Mbps (4K)${NC}\n"
printf "  ${BLUE}%-28s %-10s %-10s %s${NC}\n" "Operation" "HW (rkmpp)" "SW (cpu)" "HW Speedup"
printf "  ${BLUE}%-28s %-10s %-10s %s${NC}\n" "────────────────────────────" "──────────" "──────────" "──────────"
_cmp "720p  H.264 decode"   "$_hw_dec_h264"  "$_sw_dec_h264"
_cmp "720p  H.265 decode"   "$_hw_dec_h265"  "$_sw_dec_h265"
_cmp "720p  H.264 encode"   "$_hw_enc_h264"  "$_sw_enc_h264"
_cmp "720p  H.265 encode"   "$_hw_enc_h265"  "$_sw_enc_h265"

# 4K rows (no SW comparison — too slow)
_hw_dec_4kh264=$(_xs "$TEST_DIR/dec-h264_rkmpp-4k.log" 2>/dev/null)
_hw_dec_4kh265=$(_xs "$TEST_DIR/dec-hevc_rkmpp-4k.log" 2>/dev/null)
_hw_enc_4kh264=$(_xs "$TEST_DIR/enc-h264_rkmpp-enc-4k-h264-mp4.log" 2>/dev/null)
_hw_enc_4kh265=$(_xs "$TEST_DIR/enc-hevc_rkmpp-enc-4k-h265-mp4.log" 2>/dev/null)
_cmp "4K    H.264 decode *"  "$_hw_dec_4kh264" ""
_cmp "4K    H.265 decode *"  "$_hw_dec_4kh265" ""
_cmp "4K    H.264 encode *"  "$_hw_enc_4kh264" ""
_cmp "4K    H.265 encode *"  "$_hw_enc_4kh265" ""
printf "\n  ${BLUE}* 4K via FFmpeg is CPU-limited; VPU has ~75%% headroom (see section 5 note)${NC}\n"
printf "\n"
result_pass "Comparison table printed"

# ══════════════════════════════════════════════════════════════════════
# [10/10] SYSTEM RESOURCES
# ══════════════════════════════════════════════════════════════════════
printf "\n${YELLOW}[10/10] System resources — CPU, memory, load${NC}\n"

info "Memory:"
free -h 2>/dev/null || grep -E 'MemTotal|MemFree|MemAvailable' /proc/meminfo || true
info "CPU count: $(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo '?')"
info "CPU info:"
grep 'Hardware\|model name\|cpu MHz' /proc/cpuinfo 2>/dev/null | sort -u || true
info "Load (after tests): $(cat /proc/loadavg 2>/dev/null)"
result_pass "System resource check"

# ══════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════
printf "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "${BLUE}  Test Summary${NC}\n"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"
printf "  ${GREEN}Passed: %d${NC}  ${RED}Failed: %d${NC}  ${YELLOW}Skipped: %d${NC}\n" "$PASS" "$FAIL" "$SKIP"
printf "  Report    : %s\n" "$RESULTS_FILE"
printf "  Log dir   : %s\n" "$TEST_DIR"
printf "  Sources   : %s\n" "$SOURCE_DIR"
printf "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"

printf "\nSUMMARY: PASS=%d FAIL=%d SKIP=%d\n" "$PASS" "$FAIL" "$SKIP" >> "$RESULTS_FILE"

if [ "$FAIL" -gt 0 ]; then
    printf "\n${RED}Some tests failed — check logs in %s${NC}\n" "$TEST_DIR"
    printf "${YELLOW}Test report saved to: %s${NC}\n\n" "$RESULTS_FILE"
    exit 1
else
    printf "\n${GREEN}All tests passed!${NC}\n"
    printf "${YELLOW}Test report saved to: %s${NC}\n\n" "$RESULTS_FILE"
fi
