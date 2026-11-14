# 映码 · LumaRecode for macOS

**独立 Swift / SwiftUI 原生移植项目**，以 macOS 27 与 Apple Silicon 为目标。不修改 [Windows 原版 LumaRecode](https://github.com/MIKU552/LumaRecode) 仓库。

> **开发中，不是完整功能对等的正式版本。** 原 Windows 版的大量专业功能仍需逐模块移植和实机验证。尤其是动态 HDR、ProRes RAW、Log 色彩转换与 Apple Live Photo，不能当作已实现。

## 已提交代码

- SwiftUI / AppKit 原生 Mac 侧边栏、检查器、设置窗口、AVKit 预览与任务历史（遵循系统原生外观）。
- 独立 Swift Package \`LumaCore\`：ffprobe 探测、路径发现、FFmpeg 参数规划、可取消的任务、临时输出与输出验证。
- **软件归档预设**：x264 medium/CRF21、x265 medium/CRF23、SVT-AV1 preset4/CRF32；保留原仓库相关软件编码器参数的初始版本。
- **快速分享**：FFmpeg VideoToolbox H.264/HEVC，候选质量值 70/65；使用 \`-allow_sw 0\` 防止硬件模式悄悄退化为软件编码。不宣称质量已实测验证。
- SDR 静态照片：使用 AVFoundation + ImageIO 输出 HEIC、JPEG、PNG。
- 原生 Swift CLI：\`doctor\`、\`probe\`、\`plan\`、\`convert\` 初步实现。
- macOS 27 / Xcode 27 GitHub Actions 自动生成 Xcode 工程、Swift 测试、构建 SwiftUI .app 和 CLI。

## 尚未移植（会拒绝不安全的处理）

- Dolby Vision / HDR10+ 的逐帧元数据保留与转换。
- DJI、Samsung、Xiaomi、Apple Log 及 Apple Log 2 色彩科学。
- ProRes RAW 显影。
- 可靠的逐帧 PTS 时间轴、逐帧裁剪与多帧预览渲染。
- 原生 10-bit HDR HEIC、Apple HDR Gain Map、自适应 HDR HEIC。
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

当前版本需要用户安装原生 macOS FFmpeg 和 ffprobe，并在设置中指定或从 \`PATH\` / \`/opt/homebrew/bin\` 自动发现。

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
