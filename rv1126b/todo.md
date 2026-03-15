# RV1126B Test Findings and TODO

## Context
Latest on-device run of `ffmpeg-test.sh` completed successfully, but logs include warnings and performance patterns that need follow-up validation.

## Findings (from current run)

1. **Core functionality is working**
   - MPP decoders and encoders are detected.
   - Decode, encode, and transcode paths complete successfully.
   - `/dev/mpp_service` and `/dev/rga` exist and are accessible by `video` group.

2. **Software decode was faster than hardware decode for this test clip**
   - HW decode: ~`2.09x`
   - SW decode: ~`6.84x`
   - This is unusual if interpreted as a pure “hardware should always be faster” expectation, but it is **not automatically a driver bug**.
   - Likely contributors:
     - test input is only 1080p and easy to decode on CPU,
     - hw decode path includes extra copy/sync overhead in this benchmark style,
     - output to null sink does not reflect end-to-end pipeline gains.

3. **Timing output issue in test script**
   - Reported software decode duration is negative (`-21s`), which is invalid.
   - This indicates a measurement bug in `scripts/test-on-device.sh` timing logic (wall-clock calculation), not a codec failure.

4. **MPP warnings seen but tests still pass**
   - `mpp version: unknown ... missing VCS info`
   - `mpp_buf_slot: mismatch ...`
   - `Only rk3588/rk3576 ... frame parallel`
   - These are important to track, but in current run they appear as non-fatal warnings.

5. **RGA capability question (RGA2 support)**
   - ffmpeg-rockchip codebase includes explicit RGA2 and RGA3 handling and fallback logic (not RGA3-only).
   - Relevant implementation areas include:
     - `libavfilter/rkrga_common.c`
     - `libavfilter/rkrga_common.h`
     - `libavfilter/vf_vpp_rkrga.c`
   - Current test script does **not** run explicit RGA filter performance/format tests, so RGA path is not fully validated yet.

6. **DMA / memory handling question**
   - Code uses DRM/DMA-backed MPP buffers and DMA32/cachable flags in RKMPP hwcontext paths.
   - Relevant implementation areas include:
     - `libavutil/hwcontext_rkmpp.c`
     - `libavcodec/rkmppdec.c`
     - `libavcodec/rkmppenc.c`
   - Current test run does not explicitly validate heap selection behavior (for example `system-dma32` policy/pressure under load).

## Interpretation

- No hard failure is visible in this run.
- There is **one clear test-script correctness issue** (negative duration).
- There is **insufficient coverage** for RGA and DMA behavior to conclude optimization status for RV1126B memory architecture.

## TODO (next actions)

1. **Fix timing math in `scripts/test-on-device.sh`**
   - Replace wall-clock subtraction with robust integer timing or parse ffmpeg `time=` consistently.
   - Ensure duration cannot be negative.

2. **Add RGA functional + performance tests**
   - Add test cases for `scale_rkrga`, `vpp_rkrga`, and `overlay_rkrga`.
   - Include format matrix relevant to pipeline: NV12, NV21, YUV420P, common RGB variants.
   - Capture fps/latency and compare with non-RGA filter equivalents where applicable.

3. **Add DMA/memory stress checks**
   - Add long-run transcode tests and monitor stability.
   - Collect memory pressure indicators and buffer allocation behavior during sustained load.
   - Log relevant kernel messages before/after runs.

4. **Differentiate benchmark goals**
   - Keep current “sanity” test.
   - Add separate “throughput” profile (higher bitrate, more complex content, longer duration) where hardware acceleration benefit is more representative.

5. **Document warning policy**
   - Define which MPP warning patterns are acceptable vs. release blockers.
   - Track warning frequency across runs for regressions.

6. **[ ] Investigate libvpx SIGILL on RV1126B (optional, for performance comparison only)**
   - Note: Hardware VP9 encoding/decoding is functional, so this is not critical.

## Proposed short-term conclusion for report

Current RV1126B build is functionally usable for MPP decode/encode/transcode. However, RGA and DMA behavior are not yet comprehensively benchmarked for RV1126B-specific memory/performance tuning, and test script timing needs correction before drawing quantitative performance conclusions.