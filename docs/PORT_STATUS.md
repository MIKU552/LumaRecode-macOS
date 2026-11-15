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
| HDR10 静态 Mastering Display / MaxCLL | 软件 PQ → HEVC 初版（待专项 CI） | FFprobe SI 有理数 → x265 SEI 标度，编码后逐字段对比及不完整源拒绝；AV1/VT 不开放 |
| Log LUT | HLG 转换初版（实验性，待 CI） | 5 份原版 LUT 哈希一致，ffprobe HLG 色彩验证；真实相机色彩误差及 SDR 色调映射尚待验收 |
| ProRes RAW | 未实现 | Bayer、相机逐帧矩阵、白平衡、方向和 RAW 解码 |
| 精确帧裁剪 | 初版 | B 帧实际裁剪已测试，VFR、负 PTS 与音频时间基对齐继续验收 |
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

## Homebrew ffmpeg-full 依赖和输出验收

Actions #28 的核心单元测试、原生 App 构建、双音轨复制 / Opus 重新编码、非法色度升采样拒绝、真实 PTS 时间轴读取均已通过对应步骤。Full→Limited 范围转换因普通 Homebrew FFmpeg 缺少 zscale 被能力预检拒绝。CI 已改为安装 keg-only 的 `ffmpeg-full` 并将其置于 PATH 前列，明确验证 zscale 存在；Mac App 也优先发现它。完整 CI 结果需以后续运行为准。

## 本轮外部工具和逐帧裁剪

用户明确选择自行安装 FFmpeg。SwiftUI Settings 使用系统文件选择器配置 FFmpeg/ffprobe，并显示当前编码器与 zscale 检测结果；工具不会被内嵌或下载。根目录现有独立 MIT LICENSE。

`FrameTrimPlanner` 已按 Windows `FrameTimeline`、`Transcoder.Frames`、`NativeCli.Frames` 的行为约束实现准确显示帧范围（内核 0-based/end-exclusive，原生 UI 1-based/inclusive）；视频帧 `trim` + `setpts`，音频 `atrim` + `asetpts`，源音频不能未经裁剪复制。默认重编码 AAC。FFprobe 重新解码并核对输出总帧数后才发布文件；负 PTS 源暂时拒绝，仍需覆盖更多 VFR/音轨偏移案例。macOS CI 新增 H.264 B 帧样片端到端裁剪测试，执行结果以后续 Actions 为准。

## 原版五套 Log LUT 已原样引入（2026-11-15）

上游为 `MIKU552/LumaRecode@85b5bd2674d7071e2de5c8785334c50524b9a15b` 的五份 `Assets/*.cube`。通过 GitHub Actions 逐份下载并对比 Git blob SHA；在同一 GitHub 仓库中提交完全相同的资源对象。Mac 版的 Swift `CameraLogPipeline` 根据原版的矩阵与 Full/Limited 默认值，构建 `zscale → gbrpf32le → lut3d(tetrahedral) → setparams(HLG) → zscale(2020_ncl, error_diffusion)`。新 `EncodeSelection.logProfile` 代表显式转换请求，支持自动识别精确相机 metadata 或经用户明确确认的 Log 输入，仅软件 HEVC/AV1、至少 10 bit。输出验证按 HLG 目标而不是源 Log 色彩标签进行。新增 Swift 测试与真实 FFmpeg 10-bit Log → HLG 集成测试，**待新 Actions 完整验证**。暂不宣称 Log → SDR、RAW/动态 HDR、相机实拍色准或 macOS EDR 预览已验收。

## HDR10 静态元数据实现（2026-11-15）

新增 `HDRStaticMetadata.swift`，严格解析 Mastering Display（8 个 xy 色度、最大/最小亮度）和 MaxCLL/MaxFALL。遵循 Windows `Transcoder.HdrMetadata` 的 x265 整数单位：色度 × 50000，亮度 × 10000；只对源 BT.2020/PQ 且软件 HEVC 归档启用。编码后 `OutputVerifier` 在目标 HEVC 允许的一步量化容差内比较各字段，验证通过前不发布目标文件。缺字段、不同帧冲突、值溢出、静态 HDR 的 AV1 / VideoToolbox 路径均被拒绝。新增 Swift 单元测试与真实 FFmpeg CI 合成 HDR10 元数据保留测试；实际验收仍以最新 Actions 结果为准。

## 全片 HDR side-data 审计（新增）

`HDRSideDataSweep.swift` 对 HEVC / AV1 在正式编码前运行一次完整 `ffprobe -show_frames`，使用 `-show_entries frame=:frame_side_data=...` 和 compact 行输出以限制内存占用。新增单元测试针对第五帧才出现 HDR10+、后续首次出现静态 HDR、母版色度/内容亮度被篡改、取消与不可解码输入。Mac App 会显示审计、能力检查、编码和验收阶段。

此审计仅覆盖 FFmpeg 解码器**公开**的侧数据，不保证所有 Dolby Vision RPU 均会被识别，不能等同于动态 HDR 无损保留。完整的动态 HDR 位流审计及写回仍在待实现列表。
