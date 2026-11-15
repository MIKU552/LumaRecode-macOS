# 映码 · LumaRecode for macOS

**独立 Swift / SwiftUI 原生移植项目**，以 macOS 27 与 Apple Silicon 为目标。不修改 [Windows 原版 LumaRecode](https://github.com/MIKU552/LumaRecode) 仓库。

> **开发中，不是完整功能对等的正式版本。** 原 Windows 版的大量专业功能仍需逐模块移植和实机验证。尤其是动态 HDR、ProRes RAW、Log 色彩转换与 Apple Live Photo，不能当作已实现。

## 已提交代码

- SwiftUI / AppKit 原生 Mac 侧边栏、检查器、设置窗口、AVKit 预览与任务历史（遵循系统原生外观）。
- 独立 Swift Package \`LumaCore\`：ffprobe 探测、路径发现、FFmpeg 参数规划、可取消的任务、临时输出与输出验证。
- **软件归档预设**：x264 medium/CRF21、x265 medium/CRF23、SVT-AV1 preset4/CRF32；保留原仓库相关软件编码器参数的初始版本。
- **快速分享**：FFmpeg VideoToolbox H.264/HEVC，候选质量值 70/65；使用 \`-allow_sw 0\` 防止硬件模式悄悄退化为软件编码。不宣称质量已实测验证。
- SDR 静态照片：使用 AVFoundation + ImageIO 输出 HEIC、JPEG、PNG。
- 原生 Swift CLI：\`doctor\`、\`probe\`、\`frames\`、\`plan\`、\`convert\` 初步实现。
- macOS 27 / Xcode 27 GitHub Actions 自动生成 Xcode 工程、Swift 测试、构建 SwiftUI .app 和 CLI。

## 尚未移植（会拒绝不安全的处理）

- Dolby Vision / HDR10+ 的逐帧元数据保留与转换。
- DJI、Samsung、Xiaomi、Apple Log 及 Apple Log 2 色彩科学。
- ProRes RAW 显影。
- 逐帧裁剪与多帧预览渲染（PTS 时间轴索引与 CLI 查询已实现）。
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

## Swift 6.4 / 严格并发

使用 Xcode 27.2 的 Swift 6.4.2 编译器，Swift Package 启用 `swift-tools-version: 6.4` 与 Swift 6 语言模式，Xcode 工程设置 `SWIFT_VERSION: 6.0`（语言模式名称，**不是** 6.0 编译器版本）。已开始处理 Swift 6 严格并发诊断；最终兼容性须经后续 CI 验证。

## HDR HEIC（Apple 原生、实验性）

新增 `LumaPhotos` Swift Package：通过 AVFoundation 的 10-bit P010 解码、Core Image 的 BT.2100 PQ 色彩空间及 `CIContext.writeHEIF10Representation` 输出真正的 10-bit HDR HEIC，而不是用 SDR JPEG 冒充 HDR。当前仅启用 **10-bit BT.2020 PQ 静态 HDR、无 Dolby Vision/HDR10+** 的视频输入。该路径已接入照片工作区，**尚需 CI、实机色彩及 Apple Photos 检查**；HLG、HDR Gain Map 和 Live Photo 继续开发。

## 外部 FFmpeg（不随应用分发）

本项目的发行版不会包含 FFmpeg、ffprobe 或其编解码器。用户自行安装，例如 `brew install ffmpeg-full`，也可在 macOS 系统「设置 → 媒体工具」中用原生文件选择器指定其他 FFmpeg/ffprobe 路径。设置页提供实际编码器与 `zscale` 滤镜能力诊断。

项目根目录的 `LICENSE` 为 MIT，仅管理项目自身代码和资源。自行安装的 FFmpeg 及 x264/x265 等依赖遵守其各自许可。CI 使用 Homebrew 临时安装工具进行测试，构建 Artifact 不打包这些工具。

## 精确逐帧裁剪（初版）

Swift Package 提供 `FrameTrimPlanner`，支持 CLI `--start-frame / --end-frame`（从零开始，终点不包含）或 `--start-time / --end-time`。Mac 原生 Inspector 提供从第 1 帧开始的包含式选择器，内部统一映射到 PTS 时间轴。裁剪会重新编码音轨（默认 AAC），并在发布前解码检查帧数。此阶段不启用依赖关键帧位置的快速输入 seek，优先保证 B 帧素材处理正确；变帧率、特殊负 PTS、音频偏移需要继续验证。
