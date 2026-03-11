#!/usr/bin/env bash

set -u

FFMPEG_BIN="${FFMPEG_BIN:-/usr/local/bin/ffmpeg}"
FFPROBE_BIN="${FFPROBE_BIN:-/usr/local/bin/ffprobe}"
INPUT_FILE="${1:-mov_bbb.mp4}"
DURATION_SEC="${DURATION_SEC:-15}"
WORKDIR="${WORKDIR:-$(pwd)}"
LOG_DIR="$WORKDIR/logs"
TS="$(date +%Y%m%d-%H%M%S)"
REPORT_MD="$WORKDIR/rv1126b-ffmpeg-benchmark-$TS.md"
REPORT_CSV="$WORKDIR/rv1126b-ffmpeg-benchmark-$TS.csv"
SUMMARY_TMP="$WORKDIR/.rv1126b-ffmpeg-benchmark-$TS.summary.tmp"

mkdir -p "$LOG_DIR"
rm -f "$SUMMARY_TMP"

if [ ! -x "$FFMPEG_BIN" ]; then
  echo "ERROR: ffmpeg not found/executable at $FFMPEG_BIN"
  exit 1
fi

if [ ! -x "$FFPROBE_BIN" ]; then
  echo "ERROR: ffprobe not found/executable at $FFPROBE_BIN"
  exit 1
fi

if [ ! -f "$INPUT_FILE" ]; then
  echo "ERROR: input file not found: $INPUT_FILE"
  echo "Usage: $0 [input_file]"
  exit 1
fi

NCPU="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
[ -n "$NCPU" ] || NCPU=1

get_proc_jiffies() {
  local pid="$1"
  awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null || echo 0
}

get_total_jiffies() {
  awk '/^cpu /{sum=0; for(i=2;i<=NF;i++) sum+=$i; print sum}' /proc/stat 2>/dev/null
}

get_rss_kb() {
  local pid="$1"
  awk '/^VmRSS:/{print $2}' "/proc/$pid/status" 2>/dev/null || echo 0
}

md_escape() {
  echo "$1" | sed 's/|/\\|/g'
}

video_codec="$($FFPROBE_BIN -v error -select_streams v:0 -show_entries stream=codec_name -of csv=p=0 "$INPUT_FILE" 2>/dev/null)"

rkmpp_decoder=""
case "$video_codec" in
  h264) rkmpp_decoder="h264_rkmpp" ;;
  hevc) rkmpp_decoder="hevc_rkmpp" ;;
  av1) rkmpp_decoder="av1_rkmpp" ;;
  vp8) rkmpp_decoder="vp8_rkmpp" ;;
  vp9) rkmpp_decoder="vp9_rkmpp" ;;
  mpeg1video) rkmpp_decoder="mpeg1_rkmpp" ;;
  mpeg2video) rkmpp_decoder="mpeg2_rkmpp" ;;
  mpeg4) rkmpp_decoder="mpeg4_rkmpp" ;;
  mjpeg) rkmpp_decoder="mjpeg_rkmpp" ;;
  h263) rkmpp_decoder="h263_rkmpp" ;;
esac

report_header() {
  {
    echo "# RV1126B FFmpeg Benchmark Report"
    echo
    echo "- **Timestamp**: $(date -Iseconds)"
    echo "- **Hostname**: $(hostname)"
    echo "- **Kernel**: $(uname -srmo 2>/dev/null || uname -a)"
    echo "- **ffmpeg**: $($FFMPEG_BIN -hide_banner -version | head -n 1)"
    echo "- **CPU cores**: $NCPU"
    echo "- **Input file**: $INPUT_FILE"
    echo "- **Input codec**: ${video_codec:-unknown}"
    echo "- **Detected RKMPP decoder**: ${rkmpp_decoder:-none}"
    echo "- **Test duration per encode test**: ${DURATION_SEC}s"
    echo
    echo "## Results"
    echo
    echo "| Test | Status | Exit | Duration(s) | Avg CPU% (top-style) | Peak CPU% | Avg RSS (MB) | Max RSS (MB) | FFmpeg speed | FFmpeg fps | Log |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|"
  } > "$REPORT_MD"

  {
    echo "test,status,exit,duration_s,avg_cpu_pct,peak_cpu_pct,avg_rss_mb,max_rss_mb,ffmpeg_speed,ffmpeg_fps,log"
  } > "$REPORT_CSV"
}

run_test() {
  local test_name="$1"
  local cmd="$2"
  local log_file="$LOG_DIR/${TS}-${test_name}.log"

  echo "[RUN] $test_name"
  echo "[CMD] $cmd"

  local start_s end_s duration_s
  local sample_count=0
  local cpu_sum="0"
  local cpu_max="0"
  local rss_sum_kb=0
  local rss_max_kb=0

  start_s="$(date +%s)"

  bash -c "$cmd" > "$log_file" 2>&1 &
  local pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    local p1 t1 p2 t2 dp dt
    local cpu_top rss_kb

    p1="$(get_proc_jiffies "$pid")"
    t1="$(get_total_jiffies)"
    sleep 1

    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi

    p2="$(get_proc_jiffies "$pid")"
    t2="$(get_total_jiffies)"
    dp=$((p2 - p1))
    dt=$((t2 - t1))

    if [ "$dt" -gt 0 ]; then
      cpu_top="$(awk -v dp="$dp" -v dt="$dt" -v n="$NCPU" 'BEGIN{printf "%.2f", (dp/dt)*100*n}')"
      cpu_sum="$(awk -v a="$cpu_sum" -v b="$cpu_top" 'BEGIN{printf "%.2f", a+b}')"
      cpu_max="$(awk -v a="$cpu_max" -v b="$cpu_top" 'BEGIN{printf "%.2f", (b>a)?b:a}')"
      sample_count=$((sample_count + 1))
    fi

    rss_kb="$(get_rss_kb "$pid")"
    [ -n "$rss_kb" ] || rss_kb=0
    rss_sum_kb=$((rss_sum_kb + rss_kb))
    if [ "$rss_kb" -gt "$rss_max_kb" ]; then
      rss_max_kb="$rss_kb"
    fi
  done

  wait "$pid"
  local exit_code=$?

  end_s="$(date +%s)"
  duration_s=$((end_s - start_s))

  local cpu_avg="0.00"
  local rss_avg_mb="0.00"
  local rss_max_mb="0.00"

  if [ "$sample_count" -gt 0 ]; then
    cpu_avg="$(awk -v s="$cpu_sum" -v c="$sample_count" 'BEGIN{printf "%.2f", s/c}')"
    rss_avg_mb="$(awk -v s="$rss_sum_kb" -v c="$sample_count" 'BEGIN{printf "%.2f", (s/c)/1024}')"
  fi
  rss_max_mb="$(awk -v m="$rss_max_kb" 'BEGIN{printf "%.2f", m/1024}')"

  local ff_speed ff_fps
  ff_speed="$(grep -oE 'speed=[0-9]+(\.[0-9]+)?x' "$log_file" | tail -1 | cut -d= -f2 | tr -d 'x')"
  ff_fps="$(grep -oE 'fps=[0-9]+(\.[0-9]+)?' "$log_file" | tail -1 | cut -d= -f2)"
  [ -n "$ff_speed" ] || ff_speed="n/a"
  [ -n "$ff_fps" ] || ff_fps="n/a"

  local status="PASS"
  if [ "$exit_code" -ne 0 ]; then
    status="FAIL"
  fi

  {
    echo "| $(md_escape "$test_name") | $status | $exit_code | $duration_s | $cpu_avg | $cpu_max | $rss_avg_mb | $rss_max_mb | $ff_speed | $ff_fps | $(md_escape "$log_file") |"
  } >> "$REPORT_MD"

  {
    echo "$test_name,$status,$exit_code,$duration_s,$cpu_avg,$cpu_max,$rss_avg_mb,$rss_max_mb,$ff_speed,$ff_fps,$log_file"
  } >> "$REPORT_CSV"

  {
    echo "$cpu_avg|$test_name|$status|$duration_s|$cpu_max|$rss_avg_mb|$rss_max_mb|$ff_speed|$ff_fps"
  } >> "$SUMMARY_TMP"

  echo "[DONE] $test_name => $status (exit=$exit_code)"
}

report_footer() {
  {
    echo
    echo "## Compact Summary (sorted by Avg CPU%)"
    echo
    echo "| Test | Status | Avg CPU% | Peak CPU% | Avg RSS (MB) | Max RSS (MB) | Speed | FPS | Duration(s) |"
    echo "|---|---:|---:|---:|---:|---:|---:|---:|---:|"
  } >> "$REPORT_MD"

  if [ -f "$SUMMARY_TMP" ]; then
    sort -t'|' -k1,1nr "$SUMMARY_TMP" | while IFS='|' read -r avg_cpu test_name status duration_s cpu_max rss_avg_mb rss_max_mb ff_speed ff_fps; do
      {
        echo "| $(md_escape "$test_name") | $status | $avg_cpu | $cpu_max | $rss_avg_mb | $rss_max_mb | $ff_speed | $ff_fps | $duration_s |"
      } >> "$REPORT_MD"
    done
  fi

  {
    echo
    echo "## Notes"
    echo
    echo "- CPU% shown is sampled from /proc using top-style scaling (can exceed 100 on multi-core systems)."
    echo "- RSS is process resident memory sampled once per second while each test runs."
    echo "- Detailed stderr/stdout logs are available under: $LOG_DIR"
    echo "- CSV export is available at: $REPORT_CSV"
  } >> "$REPORT_MD"
}

report_header

run_test "encode_h264_rkmpp" \
  "$FFMPEG_BIN -hide_banner -stats -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -t $DURATION_SEC -vf format=nv12 -c:v h264_rkmpp -b:v 4M -g 60 -f null -"

run_test "encode_hevc_rkmpp" \
  "$FFMPEG_BIN -hide_banner -stats -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -t $DURATION_SEC -vf format=nv12 -c:v hevc_rkmpp -b:v 4M -g 60 -f null -"

run_test "encode_mjpeg_rkmpp" \
  "$FFMPEG_BIN -hide_banner -stats -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -t $DURATION_SEC -vf format=yuvj420p -c:v mjpeg_rkmpp -q:v 5 -f null -"

run_test "encode_mpeg4_software" \
  "$FFMPEG_BIN -hide_banner -stats -re -f lavfi -i testsrc2=size=1920x1080:rate=30 -t $DURATION_SEC -vf format=yuv420p -c:v mpeg4 -b:v 4M -g 60 -f null -"

if [ -n "$rkmpp_decoder" ]; then
  run_test "decode_${rkmpp_decoder}" \
    "$FFMPEG_BIN -hide_banner -stats -c:v $rkmpp_decoder -i '$INPUT_FILE' -f null -"
fi

run_test "decode_software_auto" \
  "$FFMPEG_BIN -hide_banner -stats -i '$INPUT_FILE' -f null -"

report_footer

echo

echo "Benchmark report generated: $REPORT_MD"
echo "CSV report generated: $REPORT_CSV"
echo "Per-test logs directory: $LOG_DIR"

rm -f "$SUMMARY_TMP"
