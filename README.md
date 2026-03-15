## RV1126B-P — Build, Test & Performance Validation

> **No source code modifications.** The upstream [nyanmisaka/ffmpeg-rockchip](https://github.com/nyanmisaka/ffmpeg-rockchip) codebase (FFmpeg 6.1 + Rockchip MPP/RGA patches) compiles and runs correctly on RV1126B-P out of the box. This fork adds only CI/CD, packaging, deployment scripts, and hardware verification — all under `.github/`, `scripts/`, and `rv1126b/`.

### What this fork provides

1. **GitHub Actions CI pipeline** — cross-compiles FFmpeg against the RV1126B-P SDK sysroot, producing two build profiles:
   - `rkmpp` — hardware codecs only (MPP decoders + encoders + RGA filters)
   - `rkmpp_software` — hardware + software codecs (adds libx264, libx265, libvpx, libaom)
2. **Deployment & management scripts** (`scripts/`):
   - `install-ffmpeg-rv1126b.sh` / `uninstall-ffmpeg-rv1126b.sh` — install/remove on device
   - `deploy-to-device.sh` — deploy build artifacts over SSH
   - `test-on-device.sh` — comprehensive hardware & software codec test suite with VPU monitoring
   - `package-sysroot.sh` — package cross-compilation sysroot
   - `ffmpeg-rockchip-cross-compile-env.sh` — cross-compilation environment setup
3. **Hardware verification & documentation** (`rv1126b/`, `scripts/README.md`):
   - Full VPU performance benchmarks (720p and 4K, encode/decode/transcode)
   - Per-test CPU, RAM, and VPU utilisation monitoring
   - RKIPC VPU contention analysis and architectural findings

### Target platform

- **SoC:** RV1126B-P (quad Cortex-A7 @ 1608 MHz, Linux 6.1, aarch64)
- **VPU:** RKVENC (VEPU511, core 480 MHz) + RKVDEC (VDPU384A, AXI 297 MHz) + RKJPEGD
- **HW encoders:** H.264, H.265, MJPEG
- **HW decoders:** H.264, H.265, VP8, VP9, AV1, MJPEG
- **RGA filters:** scale_rkrga, overlay_rkrga, vpp_rkrga

### Performance summary (RKIPC stopped, 30s tests)

| Resolution | H.264 decode | H.265 decode | H.264 encode | H.265 encode |
|------------|-------------|-------------|-------------|-------------|
| **720p** 1280×720@25fps | 4.4x | 4.8x | **1.7x** | **1.6x** |
| **1080p** 1920×1080@30fps | 1.7x | 1.8x | 0.77x | 0.76x |
| **4K** 3840×2160@30fps | 0.44x* | 0.45x* | 0.17x* | 0.17x* |

720p SW baseline: libx264 encode 0.81x, libx265 encode 0.16x · HW transcode: 2.8x (H.264→H.264)
HW encode advantage at 720p: **2.1x** over libx264, **10x** over libx265

> **\* 4K is CPU-limited, not VPU-limited.** The VPU has ~75% idle headroom during 4K — FFmpeg's single-threaded pipeline on Cortex-A7 is the bottleneck. RKIPC achieves 4K@30fps via DVBM zero-copy (ISP→VPSS→VEPU, no CPU).

> **RKIPC contention:** When running (default on boot), RKIPC consumes ~85% of VEPU, reducing FFmpeg encode by ~3.5x. Stop with `/etc/init.d/S99rkipc stop`.

Full results: [`rv1126b/HARDWARE_TEST_RESULTS.md`](rv1126b/HARDWARE_TEST_RESULTS.md) · Test suite docs: [`scripts/README.md`](scripts/README.md)

### Installation

From host PC (downloads latest release and installs over SSH):

```bash
curl -fsSL https://github.com/Fanconn-RV1126B-P/ffmpeg-rockchip/releases/latest/download/install-ffmpeg-rv1126b.sh | sh -s -- <device_ip>
```

Verify on device:

```bash
ffmpeg -hide_banner -version
ffmpeg -hide_banner -decoders | grep rkmpp
ffmpeg -hide_banner -encoders | grep rkmpp
```

Run the test suite:

```bash
# From host (auto-deploys and streams output):
sh scripts/test-on-device.sh <device_ip>

# Or directly on device:
sh /tmp/test-on-device.sh
```

### Repository structure (RV1126B-P additions only)

```
.github/workflows/build.yml          # CI: cross-compile + package artifacts
scripts/
├── README.md                         # Script & test suite documentation
├── test-on-device.sh                 # HW/SW codec test suite with VPU monitoring
├── install-ffmpeg-rv1126b.sh         # Device installer
├── uninstall-ffmpeg-rv1126b.sh       # Device uninstaller
├── deploy-to-device.sh              # Deploy build over SSH
├── package-sysroot.sh               # Package sysroot for cross-compilation
└── ffmpeg-rockchip-cross-compile-env.sh  # Cross-compile environment
rv1126b/
└── HARDWARE_TEST_RESULTS.md          # Detailed VPU benchmarks & analysis
```

---

ffmpeg-rockchip
=============
This project aims to provide full hardware transcoding pipeline in FFmpeg CLI for Rockchip platforms that support MPP ([Media Process Platform](https://github.com/rockchip-linux/mpp)) and RGA ([2D Raster Graphic Acceleration](https://github.com/airockchip/librga)). This includes hardware decoders, encoders and filters. A typical target platform is RK3588/3588s based devices.

## Hightlights
* MPP decoders support up to 8K 10-bit H.264, HEVC, VP9 and AV1 decoding
* MPP decoders support producing AFBC (ARM Frame Buffer Compression) image
* MPP decoders support de-interlace using IEP (Image Enhancement Processor)
* MPP decoders support allocator half-internal and pure-external modes
* MPP encoders support up to 8K H.264 and HEVC encoding
* MPP encoders support async encoding, AKA frame-parallel
* MPP encoders support consuming AFBC image
* RGA filters support image scaling and pixel format conversion
* RGA filters support image cropping
* RGA filters support image transposing
* RGA filters support blending two images
* RGA filters support async operation
* RGA filters support producing and consuming AFBC image
* Zero-copy DMA in above stages

## How to use
The documentation is available on the [Wiki](https://github.com/nyanmisaka/ffmpeg-rockchip/wiki) page of this project.


## Codecs and filters
### Decoders/Hwaccel
```
 V..... av1_rkmpp            Rockchip MPP (Media Process Platform) AV1 decoder (codec av1)
 V..... h263_rkmpp           Rockchip MPP (Media Process Platform) H263 decoder (codec h263)
 V..... h264_rkmpp           Rockchip MPP (Media Process Platform) H264 decoder (codec h264)
 V..... hevc_rkmpp           Rockchip MPP (Media Process Platform) HEVC decoder (codec hevc)
 V..... mjpeg_rkmpp          Rockchip MPP (Media Process Platform) MJPEG decoder (codec mjpeg)
 V..... mpeg1_rkmpp          Rockchip MPP (Media Process Platform) MPEG1VIDEO decoder (codec mpeg1video)
 V..... mpeg2_rkmpp          Rockchip MPP (Media Process Platform) MPEG2VIDEO decoder (codec mpeg2video)
 V..... mpeg4_rkmpp          Rockchip MPP (Media Process Platform) MPEG4 decoder (codec mpeg4)
 V..... vp8_rkmpp            Rockchip MPP (Media Process Platform) VP8 decoder (codec vp8)
 V..... vp9_rkmpp            Rockchip MPP (Media Process Platform) VP9 decoder (codec vp9)
```

### Encoders
```
 V..... h264_rkmpp           Rockchip MPP (Media Process Platform) H264 encoder (codec h264)
 V..... hevc_rkmpp           Rockchip MPP (Media Process Platform) HEVC encoder (codec hevc)
 V..... mjpeg_rkmpp          Rockchip MPP (Media Process Platform) MJPEG encoder (codec mjpeg)
```

### Filters
```
 ... overlay_rkrga     VV->V      Rockchip RGA (2D Raster Graphic Acceleration) video compositor
 ... scale_rkrga       V->V       Rockchip RGA (2D Raster Graphic Acceleration) video resizer and format converter
 ... vpp_rkrga         V->V       Rockchip RGA (2D Raster Graphic Acceleration) video post-process (scale/crop/transpose)
```

## Important
* Rockchip BSP/vendor kernel is necessary, 5.10 and 6.1 are two tested versions.
* For the supported maximum resolution and FPS you can refer to the datasheet or TRM.
* User MUST be granted permission to access these device files.
```
# DRM allocator
/dev/dri

# DMA_HEAP allocator
/dev/dma_heap

# RGA filters
/dev/rga

# MPP codecs
/dev/mpp_service

# Optional, for compatibility with older kernels and socs
/dev/iep
/dev/mpp-service
/dev/vpu_service
/dev/vpu-service
/dev/hevc_service
/dev/hevc-service
/dev/rkvdec
/dev/rkvenc
/dev/vepu
/dev/h265e
```

## Todo
* Support MPP VP8 video encoder
* ...

## Acknowledgments

@[hbiyik](https://github.com/hbiyik) @[HermanChen](https://github.com/HermanChen) @[rigaya](https://github.com/rigaya)

---

FFmpeg README
=============

FFmpeg is a collection of libraries and tools to process multimedia content
such as audio, video, subtitles and related metadata.

## Libraries

* `libavcodec` provides implementation of a wider range of codecs.
* `libavformat` implements streaming protocols, container formats and basic I/O access.
* `libavutil` includes hashers, decompressors and miscellaneous utility functions.
* `libavfilter` provides means to alter decoded audio and video through a directed graph of connected filters.
* `libavdevice` provides an abstraction to access capture and playback devices.
* `libswresample` implements audio mixing and resampling routines.
* `libswscale` implements color conversion and scaling routines.

## Tools

* [ffmpeg](https://ffmpeg.org/ffmpeg.html) is a command line toolbox to
  manipulate, convert and stream multimedia content.
* [ffplay](https://ffmpeg.org/ffplay.html) is a minimalistic multimedia player.
* [ffprobe](https://ffmpeg.org/ffprobe.html) is a simple analysis tool to inspect
  multimedia content.
* Additional small tools such as `aviocat`, `ismindex` and `qt-faststart`.

## Documentation

The offline documentation is available in the **doc/** directory.

The online documentation is available in the main [website](https://ffmpeg.org)
and in the [wiki](https://trac.ffmpeg.org).

### Examples

Coding examples are available in the **doc/examples** directory.

## License

FFmpeg codebase is mainly LGPL-licensed with optional components licensed under
GPL. Please refer to the LICENSE file for detailed information.

## Contributing

Patches should be submitted to the ffmpeg-devel mailing list using
`git format-patch` or `git send-email`. Github pull requests should be
avoided because they are not part of our review process and will be ignored.
