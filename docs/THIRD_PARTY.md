# Third-party resources / 第三方资源

The app itself is MIT licensed. It **does not** bundle FFmpeg or FFprobe.
The bundled five .cube camera Log transforms have two license origins.

| Resource | License | Origin |
| --- | --- | --- |
| Apple Log, Apple Log 2, Samsung Log, Xiaomi Mi-Log 3D LUTs | MIT | [Original LumaRecode generator](https://github.com/MIKU552/LumaRecode/blob/85b5bd2674d7071e2de5c8785334c50524b9a15b/tools/generate_hlg_luts.py) |
| DJI Pocket 3 D-Log M to Rec.2100 HLG LUT | Apache-2.0 | [OpenOSV v0.6.4](https://github.com/Kemerd/OpenOSV/releases/tag/v0.6.4) |

The unmodified OpenOSV LUT's full original **LICENSE** and **NOTICE** are
bundled as `OpenOSV-LICENSE.txt` and `OpenOSV-NOTICE.txt` alongside the
camera LUT resources inside the `LumaCore` bundle.

## Original-project integrity

All five LUT binaries are byte-identical to the versions in the Windows
LumaRecode repository at revision `85b5bd2674d7071e2de5c8785334c50524b9a15b`.
They were compared by Git object hash before being copied.

| File | SHA-256 (from original LUT manifest) |
| --- | --- |
| `Apple_Log_to_Rec2100_HLG.cube` | `6a8947d1b9398ff5b21b91043a6871feedeb34f92d9e28129a7b662950d27ac5` |
| `Apple_Log_2_to_Rec2100_HLG.cube` | `5e0b0eb22018a8ee138928574b2fd9173ad9db19aa8eb84bb998210c98eb6910` |
| `Samsung_Log_to_Rec2100_HLG.cube` | `ecf1c7196aae39a734085be4bf50a3c0e87036397a84bb4984dc085407281ae1` |
| `REDMI_K90_MiLog_to_Rec2100_HLG.cube` | `8019f23548691365d81ac2dddf1a5300ed226269add338e3bbcd0b64c739a2f3` |
| `DJI_Osmo_DLogM_to_Rec2100_HLG_BT2408_Neutral.cube` | `123114d3353e10b39e59ae930c97d2ffdb7531f79ae2d9e7d143af03620ecd1d` |

The LUTs are camera color transformation assets, not codecs, shared
libraries or executables. Redistribution still requires retaining the
applicable third-party attributions. Refer to
[Windows LumaRecode's original third-party manifest](https://github.com/MIKU552/LumaRecode/blob/85b5bd2674d7071e2de5c8785334c50524b9a15b/Assets/THIRD_PARTY.md)
for additional provenance.
