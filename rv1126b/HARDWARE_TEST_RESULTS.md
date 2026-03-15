# FFmpeg-Rockchip Hardware Test Results
## RV1126B-P IPC Module

**Last Updated**: March 15, 2026
**Previous Test**: January 23, 2026

---

### Test Environment
- **Device**: RV1126B-P EVB v1.2
- **SoC**: Rockchip RV1126B (DT: `rockchip,rv1126bp-evb1-v12rockchip,rv1126b`)
- **CPU**: Quad-core Cortex-A7 @ 1608 MHz max (`interactive` governor)
- **RAM**: 3.9 GB
- **Camera**: Sony IMX415 (3840x2160 @ 30fps)
- **FFmpeg**: v1.0-linux6.1-ffmpeg6.1-rkmpp (profile: `rkmpp_software`)
- **Kernel**: Linux 6.1
- **RKIPC**: Compiled for RV1126B, running 4K@30fps H.265 RTSP/RTMP

---

## 1. VPU Hardware Identification

| Unit | Hardware ID | IP Block | Clocks |
|---|---|---|---|
| RKVENC (`21f40000`) | `0x50602715` | **VEPU511** | Core: 480 MHz, AXI: 396 MHz |
| RKVDEC (`22140100`) | `0x38436021` | **VDPU384A** | AXI: 297 MHz |
| RKJPEGD (`22170000`) | `0xdb1f0007` | JPEG Decoder | -- |

- **DDR**: Dual-channel, devfreq 480 / 600 MHz
- **RKVENC DT compatible**: `rockchip,rkv-encoder-rv1126b` + `rockchip,rkv-encoder-v2`
- **DVBM**: Present in RKVENC device tree (Direct Video Bus Module for ISP->VEPU online mode)
- **Frame parallelism**: Not supported on VEPU511 (only rk3588/rk3576 encoders)

---

## 2. Available Hardware Codecs

### MPP Decoders (via VDPU384A)
| Codec | FFmpeg name | Silicon support |
|---|---|---|
| H.264/AVC | `h264_rkmpp` | Functional |
| H.265/HEVC | `hevc_rkmpp` | Functional |
| VP8 | `vp8_rkmpp` | Functional |
| VP9 | `vp9_rkmpp` | Functional |
| AV1 | `av1_rkmpp` | Functional |
| MJPEG | `mjpeg_rkmpp` | Functional |
| MPEG-1 | `mpeg1_rkmpp` | MPP reports "unsupported" |
| MPEG-2 | `mpeg2_rkmpp` | MPP reports "unsupported" |
| MPEG-4 | `mpeg4_rkmpp` | MPP reports "unsupported" |
| H.263 | `h263_rkmpp` | MPP reports "unsupported" |

### MPP Encoders (via VEPU511)
| Codec | FFmpeg name | Status |
|---|---|---|
| H.264/AVC | `h264_rkmpp` | Functional |
| H.265/HEVC | `hevc_rkmpp` | Functional |
| MJPEG | `mjpeg_rkmpp` | Functional |

### RGA Filters
| Filter | Status |
|---|---|
| `scale_rkrga` | Hardware-accelerated scaling |
| `vpp_rkrga` | Video post-processing |
| `overlay_rkrga` | Hardware overlay |

### Device Nodes
- `/dev/mpp_service`
- `/dev/rga`

---

## 3. Performance Benchmarks

> **Critical finding**: RKIPC runs continuously on this device, encoding 4K@30fps H.265
> for RTSP/RTMP streaming. This consumes **~85% of VEPU511**. All earlier benchmarks
> (January 23, 2026) were run with RKIPC contending for the VPU, producing misleadingly
> low numbers. The benchmarks below were run with RKIPC stopped, giving the VPU
> exclusively to FFmpeg.

### 3.1 Encode Performance (VEPU511 exclusive)

Source: `testsrc2` filter -> `-pix_fmt yuv420p` -> MPP encoder. Duration: 10s (720p/1080p), 5s (4K).

| Resolution | Codec | FPS | Speed | Bitrate | VEPU Load |
|---|---|---|---|---|---|
| 1280x720 | H.264 | **203** | **8.07x** | 2 Mbps | 56% |
| 1920x1080 | H.264 | **99** | **3.93x** | 4 Mbps | 59% |
| 3840x2160 | H.264 | **28** | **1.10x** | 4 Mbps | 66% |
| 3840x2160 | HEVC | **27** | **1.07x** | 4 Mbps | 66% |

**Analysis**:
- 720p and 1080p encode are heavily CPU-limited (VEPU only 56-59% utilized -- the Cortex-A7
  cannot generate `testsrc2` frames fast enough to saturate the VPU).
- 4K encode at 66% VEPU utilization confirms CPU-limited: the quad Cortex-A7 at 1608 MHz
  is the bottleneck generating 4K YUV frames, not the encoder hardware.
- **Real-world encode from ISP/camera feed (zero-copy) would be significantly faster** -- see
  Section 5 (RKIPC Analysis).

### 3.2 Decode Performance (VDPU384A exclusive)

Source: MPP-encoded test files. Decode to null output.

| Resolution | Codec | FPS | Speed | VDPU Load |
|---|---|---|---|---|
| 1280x720 | H.264 | **126** | **5.02x** | 18% |
| 1280x720 | HEVC | **130** | **5.18x** | 19% |
| 1920x1080 | H.264 | **57** | **2.26x** | 21% |
| 1920x1080 | HEVC | **59** | **2.34x** | 19% |

**Analysis**:
- VDPU384A utilization is low (18-21%), indicating FFmpeg's frame management and
  demux overhead is the bottleneck, not the decode hardware.
- HEVC decode is slightly faster than H.264 at the same resolution (the bitstreams
  are smaller at equivalent quality).
- All decode tests exceed real-time comfortably.

### 3.3 Transcode Performance (HW decode -> HW encode, exclusive)

Pipeline: `h264_rkmpp` decode -> `h264_rkmpp`/`hevc_rkmpp` encode.

| Resolution | Pipeline | FPS | Speed |
|---|---|---|---|
| 1280x720 | H.264 -> H.264 | **79** | **3.15x** |
| 1280x720 | H.264 -> HEVC | **79** | **3.14x** |
| 1920x1080 | H.264 -> H.264 | **37** | **1.46x** |
| 1920x1080 | H.264 -> HEVC | **37** | **1.46x** |

**Analysis**:
- 1080p transcode at 1.46x realtime -- comfortably real-time for 25/30fps content.
- Transcode speed is encode-limited (decode is much faster than encode).
- H.264->HEVC and H.264->H.264 transcode at identical speed, confirming VEPU511
  processes both codecs at the same throughput.

### 3.4 Impact of RKIPC VPU Contention

When RKIPC is running (4K@30fps H.265 encode for RTSP/RTMP streaming):

| Scenario | VEPU Load | FFmpeg 720p H.264 Encode |
|---|---|---|
| RKIPC only (no FFmpeg) | **85%** | -- |
| RKIPC + FFmpeg 720p encode | **95%** | 33 fps (1.33x) |
| FFmpeg only (RKIPC stopped) | **56%** | 203 fps (8.07x) |

**Key takeaway**: RKIPC's continuous 4K encoding consumes 85% of the VEPU, leaving
only ~10-15% for FFmpeg. This reduces FFmpeg encode throughput by **~6x**. If FFmpeg
must encode simultaneously with RKIPC, expect degraded performance. Consider stopping
RKIPC or switching it to a lower resolution when FFmpeg encoding is needed.

### 3.5 January 23 vs March 15 Comparison

| Test | Jan 23 (with RKIPC) | Mar 15 (exclusive VPU) | Improvement |
|---|---|---|---|
| 1080p H.264 decode | 32 fps | **57 fps** | 1.8x |
| 1080p H.264 encode | 28 fps | **99 fps** | 3.5x |
| 1080p H.264 transcode | 15 fps | **37 fps** | 2.5x |

All January 23 numbers were artificially low due to RKIPC VPU contention.

---

## 4. VPU Load Monitoring

The kernel exposes real-time VPU utilization via `/proc/mpp_service/load`.

### Enable monitoring
```bash
# Set sampling interval (milliseconds)
echo 1000 > /proc/mpp_service/load_interval
```

### Read VPU load
```bash
cat /proc/mpp_service/load
```

**Example output** (during 720p H.264 encode + RKIPC):
```
21f40000.rkvenc           load:  95.17% utilization:  92.32%
22140100.rkvdec           load:   0.00% utilization:   0.00%
22170000.jpegd            load:   0.00% utilization:   0.00%
```

### Disable monitoring
```bash
echo 0 > /proc/mpp_service/load_interval
```

### Continuous monitoring during encode
```bash
# Terminal 1: Start encode
ffmpeg -f lavfi -i testsrc2=size=1280x720:rate=25:duration=30 \
       -pix_fmt yuv420p -c:v h264_rkmpp -b:v 2M /tmp/test.mp4

# Terminal 2: Monitor VPU every second
echo 1000 > /proc/mpp_service/load_interval
watch -n 1 cat /proc/mpp_service/load
```

### Interpretation guide

| Metric | Meaning |
|---|---|
| `load` | Percentage of time the hardware unit was busy (includes idle stalls) |
| `utilization` | Percentage of time the hardware was actively processing (excludes stalls) |
| Gap between load and utilization | DDR bandwidth stalls or pipeline bubbles |

**Field reference**:
- `21f40000.rkvenc` = VEPU511 (H.264/H.265/MJPEG encoder)
- `22140100.rkvdec` = VDPU384A (multi-format decoder)
- `22170000.jpegd` = JPEG decoder

---

## 5. RKIPC vs FFmpeg: Why RKIPC achieves 4K@30fps

### The question

RKIPC encodes 4K@30fps H.265 continuously using only 85% of the VEPU511.
FFmpeg can only manage 27-28 fps at 4K with 66% VPU utilization (CPU-limited).
Why the difference?

### RKIPC pipeline architecture

```
IMX415 sensor -> ISP (rv1126b-rkisp) -> VPSS -> VEPU511 -> RTSP/RTMP
                      |                   ^
                   /dev/video*      DMA zero-copy
                                   AFBC compressed
```

**RKIPC configuration** (`/userdata/rkipc.ini`):
```ini
[video.source]
vpss_proc_dev          = vpss
enable_compress        = 1          # AFBC (ARM Frame Buffer Compression)
enable_wrap            = 0          # Wrap/line-buffer mode (disabled in current config)
buffer_line            = 540        # h/4 = 2160/4 (for wrap mode when enabled)

[video.0]
max_width              = 3840
max_height             = 2160
output_data_type       = H.265
dst_frame_rate_num     = 30
max_rate               = 8192       # kbps
enable_refer_buffer_share = 1
```

Key features of RKIPC's pipeline:
1. **Zero-copy DMA path**: ISP -> VPSS -> VENC are all connected via hardware DMA.
   No CPU memcpy at any stage. Frames never touch CPU cache.
2. **AFBC compression** (`enable_compress = 1`): Frames stay compressed in DDR,
   reducing bandwidth by ~50%. VEPU511 has native AFBC decode support.
3. **Reference buffer sharing** (`enable_refer_buffer_share = 1`): Encoder reference
   frames share memory allocation, reducing DDR footprint.
4. **VPSS hardware processing**: Video post-processing (scaling, crop, rotation)
   runs in dedicated hardware, not CPU.
5. **No software overhead**: No demuxer, no packet management, no AVFrame allocation.
   The firmware-level pipeline runs entirely in kernel/hardware space.

### FFmpeg pipeline architecture

```
testsrc2 (CPU) -> av_hwframe_transfer_data() -> DMA buffer -> VEPU511 -> muxer
     ^                    ^
  Cortex-A7          CPU memcpy
  generates           uncompressed
  YUV frames          NV12 format
```

Bottlenecks in FFmpeg's path:
1. **CPU frame generation**: `testsrc2` at 4K generates ~12.4 MB NV12 frames using
   the quad Cortex-A7 -- this alone limits throughput.
2. **CPU -> DMA copy**: `av_hwframe_transfer_data()` in `rkmppenc.c` copies every
   frame from CPU memory to a DMA-mapped MppBuffer. At 4K NV12 (12.4 MB/frame x 25fps
   = 310 MB/s), this saturates the memory bus.
3. **Uncompressed DDR traffic**: No AFBC -- raw NV12 in DDR means 2x the bandwidth
   vs RKIPC's compressed path.
4. **FFmpeg overhead**: Packet management, frame reference counting, filter graph
   evaluation, muxer buffering -- all run on CPU.

### Why 4K encode shows 66% VPU but only 28fps

The VEPU511 is **idle 34% of the time** waiting for the CPU to deliver frames.
The Cortex-A7 cannot generate + copy 4K frames fast enough to keep the VPU fed.
The VPU *could* encode faster -- it just is not receiving frames fast enough.

This is proven by the 720p/1080p results where the VPU is 56-59% utilized at
203/99 fps respectively -- the CPU cannot keep up with the VPU even at 720p.

### Can FFmpeg match RKIPC's 4K@30fps?

**For live camera encoding**: No -- not through the standard MPP API. RKIPC uses
Rockchip's proprietary VPSS + VENC pipeline with kernel-level zero-copy and AFBC.
FFmpeg's `rkmppenc.c` uses the MPP user-space API which requires frames in DDR.

**For file transcode** (decode -> encode): Closer, because HW decode outputs
`DRM_PRIME` frames that can pass to the encoder with minimal copying. The 1080p
transcode at 37fps (1.46x) confirms this works well. 4K transcode would be limited
by the combined decode + encode VPU scheduling.

**For ISP-sourced zero-copy encode**: Would require a custom V4L2 -> MPP pipeline
bypassing FFmpeg's frame management, similar to what RKIPC does. This is outside
FFmpeg's architecture.

### DVBM (Direct Video Bus Module)

The RV1126B RKVENC device tree includes a DVBM node (`/proc/device-tree/rkvenc@*/dvbm`),
which enables ISP -> VEPU "online mode" where CTU rows flow directly from the ISP to the
encoder via an internal bus, bypassing DDR entirely. This is the ultimate zero-copy path.

Current RKIPC config has `enable_wrap = 0` (wrap/online mode disabled), meaning it uses
the standard VPSS -> VENC DMA path with AFBC. Enabling wrap mode could reduce VEPU
utilization further, but is noted as "only support format = 0" in the config comments.

---

## 6. Automated Test Suite Results

**Script**: `scripts/test-on-device.sh` (30-second duration tests, CPU/RAM monitoring)

**Last run**: March 15, 2026

| Metric | Count |
|---|---|
| **PASS** | 30 |
| **FAIL** | 0 |
| **SKIP** | 15 |

**Skipped tests** (expected -- silicon limitations):
- MPEG-1, MPEG-2, MPEG-4, H.263 decode: MPP reports "unsupported" on RV1126B
- VP8, VP9 encode: Not supported by VEPU511
- AV1 encode: Not supported by VEPU511
- 4K encode tests: Skipped in automated suite (run manually above)
- `yadif_rkrga`: Not available in this FFmpeg build
- libvpx: SIGILL on RV1126B (uses ARM extensions not present on Cortex-A7)

---

## 7. Software Codec Comparison

From test suite Section [12] (30-second tests, with RKIPC running):

| Operation | HW (rkmpp) | SW (libx264/libx265) | HW Speedup |
|---|---|---|---|
| 720p H.264 encode | 33 fps* | 7 fps | 4.7x |
| 720p HEVC encode | -- | 2 fps | -- |
| 720p H.264 decode | 78 fps* | 48 fps | 1.6x |

*\* With RKIPC contention. Without RKIPC: 203 fps encode, 126 fps decode.*

Hardware acceleration provides significant speedup over software codecs on the
Cortex-A7 CPU, even when sharing the VPU with RKIPC.

---

## 8. Known Issues

### 1. RKIPC VPU Contention
- **Impact**: RKIPC uses ~85% of VEPU511 for continuous 4K H.265 streaming
- **Effect**: FFmpeg encode throughput reduced ~6x when running simultaneously
- **Workaround**: Stop RKIPC (`killall rkipc`) before FFmpeg encode benchmarks,
  or accept reduced throughput for concurrent operation

### 2. MPEG-1/2/4 and H.263 Decode Not Supported
- **Cause**: RV1126B silicon does not include these legacy decoder blocks
- **Impact**: MPP reports "unsupported" -- gracefully skipped in test suite
- **Workaround**: Use software decoders (sufficient for SD legacy content)

### 3. libvpx SIGILL
- **Cause**: Prebuilt libvpx uses ARM NEON/VFP instructions not present on Cortex-A7
- **Impact**: VP8/VP9 software encode/decode crashes with illegal instruction
- **Workaround**: Use `vp8_rkmpp`/`vp9_rkmpp` hardware decoders instead
- **Status**: Non-critical -- documented in `rv1126b/todo.md`

### 4. Frame Pixel Format
- **Issue**: Source generation must use `-pix_fmt yuv420p` explicitly
- **Cause**: `testsrc2` with libx264 defaults to `yuv444p` (High 4:4:4 profile),
  which MPP does not support
- **Fix**: Always specify `-pix_fmt yuv420p` when generating test sources

---

## 9. System Resources

| Resource | Value |
|---|---|
| **Total RAM** | 3.9 GB |
| **Used RAM** (idle) | ~205 MB |
| **CPU** | 4x Cortex-A7 @ 1608 MHz max |
| **CPU Governor** | `interactive` |
| **DDR Frequency** | 480 / 600 MHz |
| **VEPU511 Core** | 480 MHz |
| **VEPU511 AXI** | 396 MHz |
| **VDPU384A AXI** | 297 MHz |

---

## 10. Recommended Usage Patterns

### Real-time hardware transcode (up to 1080p)
```bash
ffmpeg -c:v h264_rkmpp -i input.mp4 \
       -c:v h264_rkmpp -b:v 4M \
       -y output.mp4
```

### Record camera stream (no transcode)
```bash
ffmpeg -rtsp_transport tcp -i rtsp://127.0.0.1:554/live/0 \
       -c copy -an -t 60 recording.mp4
```

### Hardware-accelerated scaling with RGA
```bash
ffmpeg -i input-4k.mp4 \
       -vf scale_rkrga=1920:1080 \
       -c:v h264_rkmpp -b:v 4M \
       -y output-1080p.mp4
```

### Stop RKIPC for maximum FFmpeg throughput
```bash
killall rkipc
ffmpeg -f lavfi -i testsrc2=size=1920x1080:rate=25:duration=60 \
       -pix_fmt yuv420p -c:v h264_rkmpp -b:v 4M /tmp/test.mp4
rkipc &  # restart when done
```

---

## 11. Conclusions

### Performance Summary

| Resolution | Encode FPS (exclusive) | Decode FPS | Transcode FPS | Real-time? |
|---|---|---|---|---|
| 720p | 203 | 126 | 79 | Yes (8x) |
| 1080p | 99 | 57 | 37 | Yes (1.5-4x) |
| 4K | 28 | -- | -- | Marginal (1.1x) |

### Key Findings
1. **ffmpeg-rockchip MPP implementation is correct** -- VEPU511 and VDPU384A are used
   efficiently. Low VPU utilization at 720p/1080p proves the CPU, not the VPU, is the
   bottleneck through FFmpeg's API path.
2. **RKIPC VPU contention was the primary cause of "slow" performance** in earlier tests.
   With exclusive VPU access, encode speeds are 3.5-6x higher.
3. **4K@30fps encoding is achievable** on VEPU511 hardware (proven by RKIPC), but
   requires a zero-copy ISP pipeline that FFmpeg's architecture cannot provide.
4. **1080p is the sweet spot** for FFmpeg on RV1126B-P: real-time transcode at 1.46x,
   encode at 3.93x, decode at 2.26x.

### Use Cases

| Use Case | Feasibility | Notes |
|---|---|---|
| 1080p recording + transcode | Excellent | 37fps transcode, well above real-time |
| 720p multi-stream processing | Excellent | 79fps transcode per stream |
| 4K camera passthrough (`-c copy`) | Excellent | No VPU needed |
| 4K FFmpeg encode from file | Marginal | 28fps, just barely real-time |
| 4K live encode (ISP->FFmpeg) | Not feasible | CPU bottleneck in FFmpeg data path |
| 4K live encode (RKIPC) | Proven | 30fps, 85% VPU, zero-copy pipeline |

---

**Test Dates**: January 23, 2026 (initial), March 15, 2026 (VPU analysis update)
**Repository**: https://github.com/Fanconn-RV1126B-P/ffmpeg-rockchip
**JIRA**: RV1126BP-34, RV1126BP-35
