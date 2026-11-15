# Windows source parity

Reference: https://github.com/MIKU552/LumaRecode

- Source of software encoder and audio presets: Assets/recommended-presets.json (copied verbatim to LumaCore/Resources).
- Core/OutputPolicy.cs: source chroma sampling, depth, full/limited range and defaults. Port incrementally with boundary tests.
- Core/Transcoder.cs: ResolveFormat/Validate/BuildPlan/VerifyAsync: enforce combinations, ffmpeg filters, source timing and verified output. VideoToolbox replaces Intel QSV only.
- Core/MediaProbe.cs: first-frame metadata, camera Log, ProRes RAW and Dolby Vision/HDR10+ evidence.
- Core/DynamicHdr.cs, Core/Hdr10PlusMetadata.cs, Core/RawDevelopment.cs: per-frame operations. Do not fake these with simple ffmpeg filters.
- Core/FrameTimeline.cs: exact B-frame/VFR PTS and trimming must not be approximated.
- Core/UltraHdrCodec.cs and MotionPhoto.cs: Apple gain-map HEIC and Live Photo require different semantics and resource pairing.

Every new ported behavior should cite a source file, preserve the relevant config, add Swift unit tests and preferably a real macOS CI media test. Current CI does not establish full feature parity.

## Native camera Log/HDR contract (current stage)

- Original implementation: `Core/Transcoder.cs:Profiles` and `LogFilter`, `Core/MediaProbe.cs:Classify`, `Assets/*.cube`.
- Native Swift: `CameraLogProfile`, `CameraLogPipeline`, `MediaProbe.detectedLogProfile`, `EncodeSelection.logProfile` and `OutputVerifier`.
- All five camera LUTs were copied byte-identically from source commit `85b5bd2674d7071e2de5c8785334c50524b9a15b` and checked by Git blob SHA on GitHub Actions. Resource files are bundled; FFmpeg is still user-supplied and is **never bundled**.
- The YCbCr decode matrix/range is independent of scene-referred RGB gamut. Use the original BT.709 vs BT.2020 NCL defaults only when tags are absent. Preserve float `gbrpf32le` before tetrahedral LUT, HLG/BT.2020 output colorimetry, and error-diffused quantization.
- Limit exposure to archive software HEVC/AV1 and 10-bit+ Log→HLG until end-to-end CI + physical camera samples prove wider support. No automatic profile guesses from camera model or file extension. No unvalidated Log→SDR/Vulkan tone mapping.

Camera LUT compliance: Pocket 3 uses OpenOSV's Apache-2.0 resource with verbatim LICENSE/NOTICE, not the MIT license used by four project-generated tables. See docs/THIRD_PARTY.md and the application resource bundle.

## HDR10 static SEI parity

Reference: Windows `Core/Transcoder.cs:HdrMetadata` (source SI rationals -> x265 integer units) and `VerifyAsync` (target SEI quantization tolerance).
Native: `HDRStaticMetadata.swift`, `MediaProbe.swift`, `EncodingPlanner.swift`, `OutputVerifier.swift`. Mastering xy ×50000; luminance ×10000; content light fields exact. Software HEVC PQ path only, all untested paths fail closed. CI: `macOS/ci/test-static-hdr10.sh` creates x265 HDR10 with known 1000/400 nits, verifies real output SEI and rejects AV1.

## Full source HDR safety audit

Windows provenance: `MediaProbe.cs` collects stream and early frame side data; `Transcoder.cs VerifyAsync` checks static HDR mastering/light metadata and dynamic HDR. Native macOS adds `HDRSideDataSweep` as a conservative extra preflight over all decoded HEVC/AV1 frames, rejecting later HDR10+/Dolby Vision evidence, unreported static SEI and inconsistent mastering/MaxCLL values. The compact ffprobe side-data stream is bounded and cancellable. This is not bitstream-level RPU preservation; DRM/proprietary metadata hidden by the decoder may still escape detection.

## Native Apple Live Photo / original Google Motion Photo

Original Windows `Core/MotionPhoto.cs` writes Google Motion Photo 1.0 as JPEG APP1 XMP plus appended MP4. Apple Live Photo requires an entirely different native format: JPEG Apple MakerNote field 17, identical QuickTime Content Identifier in the MOV, and a timed `mdta/com.apple.quicktime.still-image-time` track. A single Photos creation request can pair `.photo` and `.pairedVideo`, only after explicit user authorization. New macOS CI checks ImageIO/AVFoundation metadata and in-memory PHLivePhoto recognition using SDR video with H.264 B frames and AAC. HDR HEIC/Gain Map Live Photos remain unported. FFmpeg is external and user-provided.
