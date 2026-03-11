## RV1126B-P Status Summary (Initial)

> ⚠️ **Disclaimer:** This is an initial integration commit for testing and validation only. It is not yet a finalized production release process.

### What has been completed
- Added GitHub Actions CI/CD workflow for RV1126B-P cross-compilation and artifact packaging.
- Integrated RV1126B-P sysroot-based cross-build flow and cache strategy for repeatable builds.
- Fixed CI/runtime issues found during bring-up (toolchain/sysroot compatibility and workflow stability).
- Added and validated device-side test coverage for Rockchip MPP/RGA hardware acceleration.
- Added host-driven installer script for release consumption:
  - `scripts/install-ffmpeg-rv1126b.sh`
  - supports host execution and remote install to target device over SSH/SCP.
- Reorganized repository helper scripts into `scripts/` and test result documents into `rv1126b/`.
- Updated release notes/assets and cleaned stale release artifacts.

### Current testing scope
- Target platform: RV1126B-P (Linux 6.1, aarch64).
- Verification focus: FFmpeg binary integrity, RKMPP codec availability, and on-device hardware path validation.

### Installation (Host → Device)

Run from host PC:

```bash
curl -fsSL https://github.com/Fanconn-RV1126B-P/ffmpeg-rockchip/releases/latest/download/install-ffmpeg-rv1126b.sh | sh -s -- <device_ip>
```

On the device, set executable permission and PATH:

```bash
chmod 755 /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/ffmpeg-test.sh
export PATH=/usr/local/bin:$PATH
hash -r
```

Optional: make PATH persistent after reboot:

```bash
echo 'export PATH=/usr/local/bin:$PATH' >> /etc/profile
```

Quick verification on device:

```bash
/usr/local/bin/ffmpeg -hide_banner -version
ffmpeg -hide_banner -filters | grep -E 'scale_rkrga|vpp_rkrga|overlay_rkrga'
ffmpeg -hide_banner -buildconf | grep -E 'rkrga|rkmpp'
/usr/local/bin/ffmpeg-test.sh
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
