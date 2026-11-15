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
