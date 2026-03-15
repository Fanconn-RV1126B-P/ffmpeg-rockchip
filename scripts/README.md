# FFmpeg-Rockchip Scripts — RV1126B-P

## Scripts Overview

| Script | Purpose |
|--------|---------|
| `test-on-device.sh` | Full hardware & software codec test suite |
| `deploy-to-device.sh` | Deploy FFmpeg build to the device over SSH |
| `install-ffmpeg-rv1126b.sh` | Install FFmpeg on the device filesystem |
| `uninstall-ffmpeg-rv1126b.sh` | Remove FFmpeg from the device |
| `package-sysroot.sh` | Package cross-compilation sysroot |
| `ffmpeg-rockchip-cross-compile-env.sh` | Set up cross-compilation environment |

---

## Test Suite (`test-on-device.sh`)

### Quick Start

```sh
# From host PC (auto-deploys via SSH):
sh scripts/test-on-device.sh 192.168.1.95

# Or directly on device:
sh /usr/local/ffmpeg-rv1126b/test-on-device.sh
```

### What It Tests

Eleven sections covering the full RV1126B-P VPU capability:

| # | Section | Duration | Description |
|---|---------|----------|-------------|
| 1 | Pre-flight | ~5s | FFmpeg version, `/dev/mpp_service`, `/dev/rga`, HW codec detection |
| 2 | Source preparation | 0–5 min | Generate/cache 7 test sources in `/userdata/ffmpeg-test-sources/` |
| 3 | HW Decode 720p | ~30s | H.264, H.265, MJPEG via VDPU (30s 1280×720@25fps) |
| 4 | HW Encode 720p | ~60s | H.264, H.265, MJPEG via VEPU (30s 1280×720@25fps 2Mbps) |
| 5 | HW 1080p | ~3 min | H.264/H.265 decode + encode (30s 1920×1080@30fps 4Mbps) |
| 6 | 4K capability | ~10 min | H.264/H.265 decode + encode (30s 3840×2160@30fps 8Mbps) |
| 7 | HW Transcode | ~40s | H.264↔H.265 decode+encode pipelines (30s 720p) |
| 8 | RGA processing | ~5s | Hardware scale + colour-space conversion via RGA2 |
| 9 | SW comparison | ~8 min | CPU-only decode/encode for HW speedup baseline |
| 10 | Comparison table | instant | HW vs SW speedup summary |
| 11 | System resources | instant | CPU, memory, load |

### Per-Test Monitoring

Every test reports three resource dimensions:

```
[✓] HW encode [H.264 720p] speed:1.68x size:6.7M
       CPU: peak 54% avg 53%  |  RAM: peak 107 MiB  |  VEPU: peak 13% avg 11%  VDPU: peak 0% avg 0%
```

- **CPU**: Overall system CPU (all 4 Cortex-A7 cores), sampled at 1s intervals
- **RAM**: Peak memory usage during the test
- **VEPU**: RKVENC (encoder) utilisation from `/proc/mpp_service/load`
- **VDPU**: RKVDEC (decoder) utilisation from `/proc/mpp_service/load`

### Source Caching

Test sources are generated once and cached in `/userdata/ffmpeg-test-sources/` (a 2GB persistent eMMC partition). Subsequent runs skip generation:

```
[+] H.264 720p 30s:   cached (2.1M)
[+] H.265 720p 30s:   cached (3.1M)
[+] MJPEG 720p 10s:   cached (6.1M)
[+] 1080p H.264 30s:  cached (4.8M)
[+] 1080p H.265 30s:  cached (2.8M)
[+] 4K H.264 30s:     cached (17.2M)
[+] 4K H.265 30s:     cached (4.8M)
```

Total cache size: ~41 MB. To force regeneration, delete `/userdata/ffmpeg-test-sources/` on the device.

### Prerequisites

1. FFmpeg installed on device (via `install-ffmpeg-rv1126b.sh`)
2. **Stop RKIPC** for accurate results — it consumes ~85% of VEPU:
   ```sh
   /etc/init.d/S99rkipc stop
   ```

---

## VPU Hardware

The RV1126B-P has three video processing units:

| Unit | HW ID | Function | Clock |
|------|-------|----------|-------|
| RKVENC (VEPU511) | `0x50602715` | H.264/H.265/MJPEG encoder | core 480 MHz, AXI 396 MHz |
| RKVDEC (VDPU384A) | `0x38436021` | Multi-format decoder | AXI 297 MHz |
| RKJPEGD | `0xdb1f0007` | JPEG decoder | — |

### Supported Codecs

**Hardware decoders (VDPU):** H.264, H.265, VP8, VP9, MJPEG, AV1

**Hardware encoders (VEPU):** H.264, H.265, MJPEG

**Not supported on RV1126B silicon:** MPEG-1, MPEG-2, MPEG-4, H.263 (MPP returns "unsupported")

---

## Performance Results

### Benchmark Conditions

- RKIPC stopped (exclusive VPU access)
- CPU governor: performance (1608 MHz quad Cortex-A7)
- DDR: 480/600 MHz devfreq
- All tests use 30s duration, CBR 2Mbps (720p), 4Mbps (1080p), or 8Mbps (4K)

### 720p Performance (1280×720 @ 25fps)

| Operation | HW (rkmpp) | SW (cpu) | HW Speedup |
|-----------|-----------|----------|------------|
| H.264 decode | **4.4x** | 11.2x | 0.4x |
| H.265 decode | **4.8x** | 5.4x | 0.9x |
| H.264 encode | **1.7x** | 0.81x | **2.1x** |
| H.265 encode | **1.6x** | 0.16x | **10x** |
| MJPEG encode | **1.6x** | — | — |

**Key insight:** HW decode appears "slower" than SW decode in raw speed because ffmpeg's HW path has overhead (DMA buffer management, format conversion). The real advantage is **CPU offload** — HW decode uses ~25% CPU vs SW decode at 92–95%. This frees CPU for application logic.

HW encode is where hardware acceleration truly shines: **2.1x faster for H.264** and **10x faster for H.265** vs software, while using only ~53% CPU.

### 720p Transcode

| Pipeline | Speed |
|----------|-------|
| H.264 → H.264 | **2.8x** realtime |
| H.264 → H.265 | **2.7x** realtime |
| H.265 → H.264 | **2.9x** realtime |

### 1080p Performance (1920×1080 @ 30fps)

| Operation | HW (rkmpp) |
|-----------|------------|
| H.264 decode | **1.68x** |
| H.265 decode | **1.79x** |
| H.264 encode | 0.77x |
| H.265 encode | 0.76x |

1080p decode is comfortably above realtime. 1080p encode is below realtime (~23 fps) through FFmpeg due to the same CPU-limited lavfi pipeline that affects 4K. For real-world 1080p camera-to-encode pipelines, the VPU has ample headroom.

### 4K Performance (3840×2160 @ 30fps)

| Operation | Speed | VDPU Load | VEPU Load | CPU |
|-----------|-------|-----------|-----------|-----|
| H.264 decode | 0.44x | 16% peak | — | 25% |
| H.265 decode | 0.45x | 13% peak | — | 25% |
| H.264 encode | 0.17x | — | 14% peak | 71% |
| H.265 encode | 0.17x | — | 14% peak | 71% |

> **Why 4K is sub-realtime through FFmpeg — and why this is expected:**
>
> The VPU hardware has **~75–85% idle headroom** during 4K operations. The bottleneck is FFmpeg's **single-threaded CPU pipeline** on the Cortex-A7: demuxing, DMA buffer allocation, frame reference counting, and null muxer output all saturate one CPU core (~93% of a single core, visible as ~25% of 4 cores).
>
> The RKIPC camera pipeline achieves **4K@30fps** because it uses **DVBM (Direct Video Bus Module)** — a zero-copy hardware data path:
>
> ```
> RKIPC:   ISP → VPSS → VEPU  (zero-copy DMA, AFBC compressed, no CPU)
> FFmpeg:  CPU → memcpy → DDR → VPU → DDR → CPU  (CPU bottleneck)
> ```
>
> This is an architectural limitation of FFmpeg's processing model on this SoC, not a VPU capability issue. The device **can** stream 4K@30fps through the camera pipeline.

### Resource Usage

| Test Type | CPU (peak) | RAM (peak) |
|-----------|-----------|-----------|
| HW decode 720p | 25% | 130 MiB |
| HW encode 720p | 54% | 113 MiB |
| HW transcode 720p | 21% | 189 MiB |
| 4K decode | 26% | 341 MiB |
| 4K encode | 71% | 266 MiB |
| SW decode (H.264) | 92% | 169 MiB |
| SW encode (libx265) | 100% | 425 MiB |

System idle (no RKIPC): ~45 MiB RAM used of 3.9 GiB total.

---

## RKIPC VPU Contention

RKIPC is the default camera application that starts on boot. It continuously encodes 4K@30fps H.265 and **consumes ~85% of VEPU** even when no client is consuming the stream.

### Impact on FFmpeg

| Metric | With RKIPC | Without RKIPC | Improvement |
|--------|-----------|--------------|-------------|
| 720p H.264 encode | ~0.5x | 1.7x | **3.4x** |
| 720p transcode | ~0.8x | 2.8x | **3.5x** |
| RAM usage (idle) | ~205 MiB | ~45 MiB | -160 MiB |

### How to Stop RKIPC

```sh
# Temporary (until reboot):
/etc/init.d/S99rkipc stop

# Permanent (disable auto-start):
chmod -x /etc/init.d/S99rkipc

# Verify it's stopped:
pgrep -x rkipc && echo "STILL RUNNING" || echo "STOPPED"
```

> **Note:** MPP kernel threads (`mpp_worker_*`, `vcodec_thread_*`, `vpss`, `vrga`) will persist even after stopping RKIPC. These are kernel-space MPP infrastructure threads tied to the `mpp_service` module, not RKIPC userspace threads.

---

## Known Issues

| Issue | Status | Details |
|-------|--------|---------|
| RGA filters fail | Known | `scale_rkrga`, `vpp_rkrga` fail with "Impossible to convert between formats" — DRM_PRIME format negotiation between h264_rkmpp output and RGA filter input is not supported in this build. SW scale (`-vf scale=`) works as a fallback. |
| libvpx SIGILL | Known | Prebuilt libvpx uses ARM NEON/VFP extensions absent on Cortex-A7. Build libvpx from source with `-march=armv7-a` to fix. |
| 4K sub-realtime | By design | CPU-limited in FFmpeg's pipeline; VPU has ~75% headroom. Use RKIPC/camera pipeline for 4K. |
| MPEG-1/2/4, H.263 | Unsupported | RV1126B silicon does not implement these decoders. |

---

## Test Report Location

After each run, the test report and per-test logs are saved on the device:

```
/tmp/ffmpeg-rv1126b-test/
├── test-results.txt          # Summary of all PASS/FAIL/SKIP
├── dec-h264_rkmpp.log        # Per-test FFmpeg output
├── enc-h264_rkmpp-*.log
├── tc-*.log                  # Transcode logs
├── mon-*.log                 # Raw CPU/RAM/VPU monitoring data
└── *.mp4 / *.avi             # Encoded output files
```

Test sources (persistent across reboots):
```
/userdata/ffmpeg-test-sources/
├── source-h264.mp4           # 720p 30s H.264
├── source-h265.mp4           # 720p 30s H.265
├── source-mjpeg.avi          # 720p 10s MJPEG
├── source-1080p-h264.mp4     # 1080p 30s H.264
├── source-1080p-h265.mp4     # 1080p 30s H.265
├── source-4k-h264.mp4        # 4K 30s H.264
└── source-4k-h265.mp4        # 4K 30s H.265
```
