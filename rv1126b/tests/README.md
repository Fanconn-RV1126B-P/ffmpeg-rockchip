# RV1126B FFmpeg Performance Tests

This folder contains a repeatable benchmark script for validating FFmpeg hardware/software paths on RV1126B.

## Files

- `run_rv1126b_ffmpeg_bench.sh`: main benchmark runner
- `mov_bbb.mp4`: optional sample input file (local testing only)
- `rv1126b-ffmpeg-benchmark-*.md`: generated Markdown reports (local outputs)
- `rv1126b-ffmpeg-benchmark-*.csv`: generated CSV reports (local outputs)

## What the script tests

The script runs these checks by default:

1. Hardware encode (`h264_rkmpp`)
2. Hardware encode (`hevc_rkmpp`)
3. Hardware encode (`mjpeg_rkmpp`)
4. Software encode baseline (`mpeg4`)
5. Hardware decode (auto-mapped from input codec, e.g. `h264_rkmpp`)
6. Software decode baseline (auto)

For each test it captures:

- Exit status (PASS/FAIL)
- Runtime duration
- Average/peak CPU usage (top-style)
- Average/peak RSS memory
- FFmpeg speed/fps from logs
- Full per-test log path

## Usage

Run on RV1126B device:

```bash
cd /tmp
chmod +x run_rv1126b_ffmpeg_bench.sh
./run_rv1126b_ffmpeg_bench.sh mov_bbb.mp4
```

Run with custom duration:

```bash
DURATION_SEC=30 ./run_rv1126b_ffmpeg_bench.sh mov_bbb.mp4
```

Run with explicit ffmpeg path:

```bash
FFMPEG_BIN=/usr/local/bin/ffmpeg ./run_rv1126b_ffmpeg_bench.sh mov_bbb.mp4
```

## Outputs

- Markdown report: `rv1126b-ffmpeg-benchmark-<timestamp>.md`
- CSV report: `rv1126b-ffmpeg-benchmark-<timestamp>.csv`
- Logs directory: `logs/`

The Markdown includes:

- full detailed results table
- compact summary sorted by average CPU usage

## Notes

- CPU% can exceed 100 on multi-core systems (top-style scaling).
- Encode tests use `-re` by default for realtime pacing. Remove `-re` in script if you want maximum-throughput benchmarking.
- Current software baseline uses MPEG-4 because this build does not include `libx264` by default.
