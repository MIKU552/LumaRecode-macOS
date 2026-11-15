# 映码 · LumaRecode for macOS

**独立 Swift / SwiftUI 原生移植项目**，以 macOS 27 与 Apple Silicon 为目标。不修改 [Windows 原版 LumaRecode](https://github.com/MIKU552/LumaRecode) 仓库。

> **开发中，不是完整功能对等的正式版本。** 原 Windows 版的大量专业功能仍需逐模块移植和实机验证。尤其是动态 HDR、ProRes RAW、Log → SDR 色调映射与 Apple Live Photo，仍未完整移植；相机 Log → HLG 是新加入的实验性功能。

## 已提交代码

- SwiftUI / AppKit 原生 Mac 侧边栏、检查器、设置窗口、AVKit 预览与任务历史（遵循系统原生外观）。
- 独立 Swift Package \`LumaCore\`：ffprobe 探测、路径发现、FFmpeg 参数规划、可取消的任务、临时输出与输出验证。
- **软件归档预设**：x264 medium/CRF21、x265 medium/CRF23、SVT-AV1 preset4/CRF32；从原仓库的 JSON 直接读取软件编码参数。
- **快速分享**：FFmpeg VideoToolbox H.264/HEVC，候选质量值 70/65；使用 \`-allow_sw 0\` 防止硬件模式悄悄退化为软件编码。不宣称质量已实测验证。
- **相机 Log → HLG 初版（实验性）**：原样引入 Windows 已测试的 5 份 LUT，保留 YCbCr 输入矩阵/范围、32-bit float RGB 中间层、四面体插值、HLG/BT.2020 标签与输出验证；仅软件 HEVC/AV1、至少 10-bit。Log → SDR 尚未开放。
- SDR 静态照片：使用 AVFoundation + ImageIO 输出 HEIC、JPEG、PNG。
- 原生 Swift CLI：\`doctor\`、\`probe\`、\`frames\`、\`plan\`、\`convert\` 初步实现。
- macOS 27 / Xcode 27 GitHub Actions 自动生成 Xcode 工程、Swift 测试、构建 SwiftUI .app 和 CLI。

## 尚未移植（会拒绝不安全的处理）

- Dolby Vision / HDR10+ 的逐帧元数据保留与转换；HDR10 静态元数据的 AV1 / VideoToolbox 保留仍待验证。
- Log → SDR（原版 BT.2390 / libplacebo 色调映射）及相机 Log LUT 的实机色彩一致性验收。
- ProRes RAW 显影。
- 高级逐帧裁剪边界（VFR、负 PTS、音频起始偏移）及多帧预览渲染；B 帧/PTS 初版已实现。
- Apple HDR Gain Map、自适应 HDR HEIC（10-bit PQ HEIC 已有实验性版本）。
- 原生 Live Photo（配对 HEIC / MOV、关联元数据和 PhotoKit）。
- 完整的 CLI 参数和旧版 JSON 事件兼容、四语本地化、原生通知、全量媒体回归验证。

目前素材探测和编解码流程中的动态 HDR 检测属于第一阶段；**不能视为完整的元数据保留安全保证**，存在探测信息不足的风险。未完成的专业视频工作请继续使用 Windows 版。

## 构建

GitHub Actions 页面选择 **macOS 27 Native Build**，或推送到 \`main\` 自动触发。使用 GitHub 官方 \`xcode-27\` ARM64 托管 Runner。

产物 Artifact \`LumaRecode-macOS27-native-dev\` 包含：

- \`LumaRecode-macOS27-arm64-unsigned.zip\` — 无签名开发版 .app
- \`lumarecode-macOS27-arm64\` — Swift 原生 CLI

无签名开发产物仅用于开发验证，不代表已完成 Developer ID 签名、公证或 Mac 实机验收。

本地有 Mac 的开发者可运行：

\`\`\`bash
brew install xcodegen
xcodegen generate --spec macOS/project.yml
swift test --package-path macOS/Packages/LumaCore
open macOS/LumaRecode.xcodeproj
\`\`\`

## 运行依赖

建议安装带有 `zscale` / `zimg` 的完整原生媒体工具：`brew install ffmpeg-full`。Homebrew 普通 `ffmpeg` 版本不一定包含 zscale，可能不支持采样范围转换。App 优先查找 keg-only 的 `/opt/homebrew/opt/ffmpeg-full/bin` 和 `/usr/local/opt/ffmpeg-full/bin`；也可以在设置中手动指定其他完整版本。

软件编码器依赖 FFmpeg 构建中提供的 \`libx264\`、\`libx265\` 和 \`libsvtav1\`；硬件编码要求 \`h264_videotoolbox\` / \`hevc_videotoolbox\` 可用。某些 FFmpeg 构建没有完整的专业滤镜，请按具体功能检查能力。

## 架构与安全约定

- 完整原生 Swift，而非 .NET/Wine/Electron 运行。
- 引擎使用参数数组启动子进程，不拼接 Shell 命令。
- 编码至目标目录的独立临时文件；成功探测验证后才发布目标文件。
- 未完成的色彩功能必须提示并拒绝，不能以 SDR 截帧伪装 HDR，不能悄悄丢失已知的 Dolby Vision/HDR10+ 元数据。
- 使用原生文件选择、原生检查器和系统偏好，不复刻 WinUI 视觉。
- Apple 原生 HEIC / Live Photo 是目标格式，不使用 Google Ultra HDR/Android Motion Photo 作为 Mac 版默认方案。

## 来源与版权

项目独立重写，功能与软件预设以 [LumaRecode](https://github.com/MIKU552/LumaRecode)（MIT）为基准。第三方 FFmpeg 编解码组件与 Apple 平台组件保留各自许可要求。最终随发行版包含完整第三方声明和适用许可证。

项目状态与测试结果请以本仓库的 Actions 为准。

## 开发与 AI 协作

本 macOS 移植项目由 **[MIKU552](https://github.com/MIKU552)** 负责需求、仓库管理及最终审核和实机验收。Swift / SwiftUI 的移植代码由 **ChatGPT（GPT-6）** 在用户授权的 GitHub 连接下协助开发，开发方式与 Windows 原项目使用 Codex 的情况有所不同。

为了与 [Windows 原版 LumaRecode](https://github.com/MIKU552/LumaRecode) 的 Git 历史保持一致，AI 协作的提交消息统一使用 `Co-authored-by: Codex <codex@openai.com>` 作为共同作者署名，Git 的主作者和提交者仍是 **MIKU552**。这里的 Codex 标记是项目采用的统一协作署名，**并不表示当前 ChatGPT 以官方 @codex GitHub 账号登录、推送代码，或由 Codex 产品亲自完成这些提交**。

移植功能的实际可用性以仓库 CI、后续 macOS 实机测试及发行验收为准。

## Swift 6.4 / 严格并发

使用 Xcode 27.2 的 Swift 6.4.2 编译器，Swift Package 启用 `swift-tools-version: 6.4` 与 Swift 6 语言模式，Xcode 工程设置 `SWIFT_VERSION: 6.0`（语言模式名称，**不是** 6.0 编译器版本）。已开始处理 Swift 6 严格并发诊断；最终兼容性须经后续 CI 验证。

## HDR HEIC（Apple 原生、实验性）

新增 `LumaPhotos` Swift Package：通过 AVFoundation 的 10-bit P010 解码、Core Image 的 BT.2100 PQ 色彩空间及 `CIContext.writeHEIF10Representation` 输出真正的 10-bit HDR HEIC，而不是用 SDR JPEG 冒充 HDR。当前仅启用 **10-bit BT.2020 PQ 静态 HDR、无 Dolby Vision/HDR10+** 的视频输入。该路径已接入照片工作区，**尚需 CI、实机色彩及 Apple Photos 检查**；HLG、HDR Gain Map 和 Live Photo 继续开发。

## 外部 FFmpeg（不随应用分发）

本项目的发行版不会包含 FFmpeg、ffprobe 或其编解码器。用户自行安装，例如 `brew install ffmpeg-full`，也可在 macOS 系统「设置 → 媒体工具」中用原生文件选择器指定其他 FFmpeg/ffprobe 路径。设置页提供实际编码器与 `zscale` 滤镜能力诊断。

项目根目录的 `LICENSE` 采用 MIT，覆盖项目自主代码与四份自制相机 Log LUT。**DJI Pocket 3 D-Log M LUT 来自 OpenOSV v0.6.4，原版为 Apache-2.0**；完整原始 LICENSE 和 NOTICE 随 App LUT 资源附带，并在 [第三方声明](docs/THIRD_PARTY.md) 和 [NOTICE](NOTICE) 中注明。自行安装的 FFmpeg 及 x264/x265 等依赖遵守其各自许可。CI 使用 Homebrew 临时安装工具进行测试，构建 Artifact 不打包这些工具。

## 精确逐帧裁剪（初版）

Swift Package 提供 `FrameTrimPlanner`，支持 CLI `--start-frame / --end-frame`（从零开始，终点不包含）或 `--start-time / --end-time`。Mac 原生 Inspector 提供从第 1 帧开始的包含式选择器，内部统一映射到 PTS 时间轴。裁剪会重新编码音轨（默认 AAC），并在发布前解码检查帧数。此阶段不启用依赖关键帧位置的快速输入 seek，优先保证 B 帧素材处理正确；变帧率、特殊负 PTS、音频偏移需要继续验证。

## 原版相机 Log → HLG（实验性）

使用 Windows 原项目 `Core/Transcoder.cs` 的精确色彩管线及 `Assets/*.cube` 五份 LUT：DJI Pocket 3 D-Log M、Samsung Log、Xiaomi Mi-Log、Apple Log、Apple Log 2。文件直接储存在 Swift Package 资源中（**只是相机 LUT，不是 FFmpeg 或任何编解码器**）；构建时不从网络下载，Git SHA 已与原版固定提交校验。

通过原生检查器选择「相机 Log 色彩」或 CLI：

```bash
lumarecode convert camera.mov --purpose archive --codec hevc \\
  --log-profile applelog --interpret-log --output camera_HLG.mkv
```

`--interpret-log` 仅用于相机标签缺失或错误时手动明确确认输入为 Log；元数据匹配时不需要它。此功能只处理相机 Log → **BT.2100 HLG**，并以原版软件归档参数编码。不会将设备型号或文件名猜成特定曲线，也不会将没有通过色彩校验的输出发布。Log → SDR、RAW、动态 HDR 仍不支持。真实 Log 相机样本与 Apple EDR 显示仍需实测。

## HDR10 Mastering Display / MaxCLL 保留（初版）

基于 Windows `Core/Transcoder.cs` 的 `HdrMetadata` 与 `VerifyAsync`，Swift `HDRStaticMetadata` 从 FFprobe 的流/解码帧侧数据读取母版色度、最大/最小亮度与 MaxCLL/MaxFALL。软件 HEVC PQ 归档通过 x265 写入 `master-display`、`max-cll`、`hdr10=1`、`hdr10-opt=1`、`repeat-headers=1`，发布前再读取并按 HEVC SEI 量化步长逐字段验证。**首版仅对被探测到静态元数据的 BT.2020 PQ 素材开放软件 HEVC 归档；不支持静态元数据的 AV1、VideoToolbox 等尚未实测的组合。** 非完整、冲突或超出 SEI 范围的元数据会被拒绝。动态 HDR（Dolby Vision/HDR10+）仍不支持。首帧有限探测不保证识别整个视频中后期出现的动态元数据，仍需后续全片位流检查。

真实 FFmpeg/x265 合成样片的 Mastering Display 与 MaxCLL/MaxFALL 在编码前后已验证一致；macOS 专项 CI 以 `test-static-hdr10.sh` 的实际运行结果为准。
