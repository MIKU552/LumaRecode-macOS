# macOS 原生移植进度与验收清单

| 模块 | 状态 | 验收要求 |
| --- | --- | --- |
| SwiftUI 原生工作区 | 已提交，待 CI | macOS 27 Xcode 编译，原生 Sidebar/Inspector/Settings |
| FFprobe 素材探测 | 初版 | 与 Windows 详细探测结果逐字段对比 |
| x264/x265/SVT-AV1 软件编码 | 初版，新增 HEVC 软件转码 CI 冒烟测试 | 同一素材的命令参数、色彩标签、采样、音轨验证 |
| VideoToolbox H.264/HEVC | 初版 | Mac 设备兼容、编码质量与文件体积实测 |
| AVKit 预览 | 初版 | 非原生解码素材的后备方案、HDR 预览实测 |
| FFmpeg 进度/取消/临时输出 | 初版 | 失败、信号、覆盖、磁盘不足和长任务测试 |
| SDR HEIC/JPEG/PNG | 初版 | 图片方向、颜色与元数据检查 |
| Apple HDR HEIC | 10-bit PQ 初版（实验性、待 CI） | AVAssetReader P010 → Core Image PQ → HEIF10；HLG、色度与 EDR 实机验证待完成 |
| Gain Map HEIC | 未实现 | SDR base + HDR gain map、Photos 原生显示验证 |
| Apple Live Photo | 未实现 | paired video / still metadata、PhotoKit 导入检验 |
| Dolby Vision / HDR10+ | 未实现 | 原始动态元数据跨帧保留、无降级 |
| Log LUT | 未实现 | 原版 LUT 色彩数学、SDR/HDR 图像误差 |
| ProRes RAW | 未实现 | Bayer、相机逐帧矩阵、白平衡、方向和 RAW 解码 |
| 精确帧裁剪 | 未实现 | VFR、B 帧、负 PTS 与音视频同步 |
| CLI 全兼容 | 部分实现 | 退出码、所有参数、JSON schema 与 Windows 基线对比 |
| App 签名公证 | 未实现 | Developer ID + notarization + Gatekeeper |
| 四语本地化 | 未实现 | zh-CN/en/ja/es 系统语言行为 |
| 真机验收 | 未完成 | Apple Silicon Mac 显示、硬件编码、Live Photo |

**注意：** SwiftUI 框架原生化不等于所有专业功能已经原生重写或实现。禁止将占位的功能声明成已完成。

## Windows 源码映射

- \`Core/MediaProbe.cs\` → \`MediaProbe.swift\`（初步）
- \`Core/Models.cs\` → \`Models.swift\`（初步）
- \`Core/OutputPolicy.cs\` → \`EncodingPlanner.swift\`（初步）
- \`Core/ProcessRunner.cs\` → \`Tools.swift\`、\`ConversionSession.swift\`
- \`Core/Transcoder.cs\` → \`EncodingPlanner.swift\`、\`ConversionSession.swift\`
- \`Core/FrameTimeline.cs\`、\`Core/DynamicHdr.cs\`、\`Core/RawDevelopment.cs\` 尚未进行功能对等移植。

## 下一步

先让 macOS 27 Actions 完成 Swift 测试、Xcode 编译、生成开发版 Artifact，解决实际编译差异。之后逐模块增加回归测试和未实现的 HDR/RAW/Live Photo 能力。

## 2026-11-15 Swift 6.4 迁移

已检测 Xcode 27.1 上的 Apple Swift 6.4。核心 Package 与 SwiftUI App 正在从 Swift 5 语言模式迁移至 Swift 6 严格并发语言模式，使用 `Synchronization.Mutex` 防止输出读取竞争。**待 CI 确认编译通过**。

## Xcode 27.2 / ffprobe 增强

CI 现在优先选择已安装的 **Xcode 27.2**（Swift 6.4.2），在镜像未安装时回退到 Xcode 27 默认版本。增加 ProRes RAW `prores_raw` 检测和有限首帧 HDR10+ / Dolby Vision 元数据辅助检测；**有限首帧检测不保证全视频动态元数据安全**，后续仍需位流级完整校验。

### HDR HEIC 视频实测

新增可选的 `AppleHDRPhotoTests.testExportsPQFrameFromNative10BitVideo` 测试，由 CI 的 `media-smoke` 任务生成带 BT.2020 PQ 标签的 10-bit HEVC 样片，通过 AVAssetReader → Core Image → HEIF10 导出，并检查图片尺寸与 ImageIO 可读性。该测试**不等于真实 EDR 屏幕、HDR 亮度或 Apple Photos 的完整色彩验收**。

## CI #9: HDR PQ 测试素材修复

Actions #9 中 Xcode / Swift 严格并发编译、单元测试、SDR 软件 HEVC 转码均成功；新的 PQ → HEIC10 集成测试失败。原因是合成样片只提供了 FFmpeg 的输出色彩标签，没有通过 x265 的 `colorprim` / `transfer` / `colormatrix` 正确写入 HEVC VUI，导致 `ffprobe` 将传递函数识别为 unknown、色域为空。已在后续提交同时修正 **测试素材生成** 和 **应用软件 HEVC 编码器的 HDR/SDR VUI 写入**，添加 SDR/PQ/HLG 单元断言和缺少色彩信息时的拒绝路径。完整 PQ → HEIC10 集成测试必须由新的 Actions 证明通过；绝不通过取消测试或伪造标签的方式绕过。

### CI #10: AVFoundation 容器兼容性

已确认 HDR VUI 修复使源文件通过 BT.2020/PQ 检查；但 Runner 的 AVFoundation 阶段报出 `Cannot Decode`。合成测试 MP4 原先默认携带 `hev1` sample entry，而 Apple HLS 规范推荐 `hvc1`。下一轮测试将写入并校验 `hvc1`，并在 AVAssetReader、轨道加载、Core Image 写入阶段分别标注错误位置；仍须根据实际 CI 判断解码是否通过，不能仅凭标签推断成功。

## Swift 原生架构决定（2026-11-15）

原版 Windows 项目提供参数、格式边界及测试样本方面的权威基准，而**不决定 Mac 版的 UI / 运行时架构**。当前 macOS App 已采用 Swift 6.4.2 / Swift 6、SwiftUI `NavigationSplitView`、macOS 原生 Inspector、`@Observable`（Observation）共享状态、Apple AVKit / Core Image / ImageIO；独立 Swift Package 负责媒体规则，FFmpeg 参数由源配置驱动。SwiftUI 不复刻 WinUI，工具进程不依赖 .NET。仍需基于新 Actions 验证这次 Observation 迁移。
