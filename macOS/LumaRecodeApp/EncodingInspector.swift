import LumaCore
import SwiftUI

/// Native macOS inspector: choices follow source capabilities; original preset
/// data is read by the Swift core, not hard-coded as WinUI screen values.
struct EncodingInspector: View {
    @Environment(WorkspaceModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("工作模式") {
                Picker("处理方式", selection: $model.selection.purpose) {
                    Text("软件归档").tag(EncodePurpose.archive)
                    Text("快速分享").tag(EncodePurpose.share)
                }
                .pickerStyle(.segmented)
                Text(model.selection.purpose == .archive
                     ? "使用原版软件编码预设，在 Apple Silicon 上执行。"
                     : "通过 Apple VideoToolbox 使用硬件编码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("视频") {
                Picker("编码", selection: $model.selection.codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        if model.selection.purpose == .archive || codec != .av1 {
                            Text(codec.title).tag(codec)
                        }
                    }
                }
                .onChange(of: model.selection.purpose) { _, purpose in
                    // Do not send the local @Bindable projection to callbacks.
                    let workspace = self.model
                    if purpose == .share {
                        if workspace.selection.codec == .av1 { workspace.selection.codec = .hevc }
                        workspace.selection.variant = .standard
                    }
                    workspace.selection.sampling = .automatic
                    workspace.selection.bitDepth = .automatic
                }
                .onChange(of: model.selection.codec) { _, codec in
                    let workspace = self.model
                    if codec != .av1 { workspace.selection.variant = .standard }
                    workspace.selection.sampling = .automatic
                    workspace.selection.bitDepth = .automatic
                }
                if model.selection.purpose == .archive {
                    LabeledContent("编码模式", value: "FFmpeg 软件")
                    LabeledContent("预设", value: presetLabel)
                    if model.selection.codec == .av1 {
                        Picker("AV1 档位", selection: $model.selection.variant) {
                            Text("标准 · preset 4").tag(EncodingVariant.standard)
                            Text("快速备用 · preset 6").tag(EncodingVariant.fast)
                        }
                    }
                } else {
                    LabeledContent("编码模式", value: "VideoToolbox")
                    LabeledContent("质量参考", value: model.selection.codec == .hevc ? "65" : "70")
                }
            }
            Section("相机 Log 色彩") {
                Picker("色彩转换", selection: $model.selection.logProfile) {
                    Text("原样编码（不使用 LUT）").tag(nil as CameraLogProfile?)
                    ForEach(CameraLogProfile.allCases) { profile in
                        Text(profile.title).tag(profile as CameraLogProfile?)
                    }
                }
                .onChange(of: model.selection.logProfile) { _, profile in
                    let workspace = self.model
                    if profile != nil {
                        workspace.selection.purpose = .archive
                        if workspace.selection.codec == .avc {
                            workspace.selection.codec = .hevc
                        }
                        workspace.selection.bitDepth = .automatic
                    }
                }
                if let profile = model.selection.logProfile {
                    LabeledContent("输入曲线", value: profile.title)
                    LabeledContent("输出", value: "BT.2100 HLG · BT.2020")
                    if let info = model.media, info.sourceColor != .log {
                        Toggle(
                            "明确将素材解释为相机 Log",
                            isOn: $model.selection.interpretAsLog
                        )
                        Text("仅在原片未正确标记 Log 时使用。错误的输入解释会改变颜色，应用不会凭文件名或相机型号猜测。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Label("使用 Windows 原版浮点 LUT 和四面体插值。首版仅支持软件 HEVC/AV1 归档、10-bit 以上的 Log → HLG；Log → SDR 尚未移植。", systemImage: "camera.filters")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if model.media?.sourceColor == .log {
                    Label("检测到 Log 素材，请选择与原片匹配的相机曲线。", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section("格式") {
                Picker("色度采样", selection: $model.selection.sampling) {
                    Text("自动").tag(SamplingChoice.automatic)
                    Text("保持原片").tag(SamplingChoice.source)
                    ForEach([SamplingChoice.yuv420, .yuv422, .yuv444, .gray]) { format in
                        if isSamplingSupported(format) {
                            Text(samplingLabel(format))
                                .tag(format)
                        }
                    }
                }
                Picker("位深", selection: $model.selection.bitDepth) {
                    Text("自动").tag(BitDepthChoice.automatic)
                    ForEach([BitDepthChoice.eight, .ten, .twelve]) { depth in
                        if isDepthSupported(depth) {
                            Text("\(depth.rawValue) 位").tag(depth)
                        }
                    }
                }
                Picker("采样范围", selection: $model.selection.colorRange) {
                    Text("自动").tag(SampleRangeChoice.automatic)
                    Text("保持原片").tag(SampleRangeChoice.source)
                    Text("Limited").tag(SampleRangeChoice.limited)
                    Text("Full").tag(SampleRangeChoice.full)
                }
                Text("受素材采样和原版 OutputPolicy 的约束。范围变化会转换像素数值，不只改标签。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("音频") {
                Picker("音轨处理", selection: $model.selection.audio) {
                    Text("自动").tag(AudioChoice.automatic)
                    Text("复制音轨").tag(AudioChoice.copy)
                    Text("AAC · 256 kbps").tag(AudioChoice.aac)
                    Text("Opus · 192 kbps").tag(AudioChoice.opus)
                }
                Text("归档默认复制所有音轨。有损音频选项按原版推荐配置执行。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("逐帧裁剪") {
                Toggle("按显示帧裁剪", isOn: $model.frameTrimEnabled)
                if model.frameTrimEnabled {
                    if let timeline = model.frameTimeline {
                        LabeledContent("素材帧数", value: "\(timeline.count)")
                        Stepper(value: $model.trimStartFrame, in: 1...max(1, model.trimEndFrame)) {
                            Text("起始帧（含）：\(model.trimStartFrame)")
                        }
                        Stepper(value: $model.trimEndFrame, in: model.trimStartFrame...timeline.count) {
                            Text("结束帧（含）：\(model.trimEndFrame)")
                        }
                        Text("与 Windows 版一致：界面从第 1 帧编号，内部使用从 0 开始、终点不包含的 PTS 帧范围。")
                            .font(.caption).foregroundStyle(.secondary)
                        if model.selection.audio == .copy {
                            Label("裁剪时不能复制音轨，请选择自动、AAC 或 Opus。", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange).font(.caption)
                        } else if model.selection.audio == .automatic {
                            Text("裁剪时自动将音轨重新编码为 AAC，以避免原音轨未经裁剪。")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Button("建立精确 PTS 帧索引") {
                            self.model.loadFrameTimeline()
                        }
                        .disabled(model.media == nil || model.indexingFrames)
                        if model.indexingFrames {
                            ProgressView("正在读取显示帧…")
                                .controlSize(.small)
                        }
                    }
                }
            }
            Section("输入色彩") {
                if let info = model.media {
                    LabeledContent("类别", value: info.sourceColor.rawValue.uppercased())
                    LabeledContent("传递函数", value: info.transfer.isEmpty ? "未知" : info.transfer)
                    LabeledContent("色域", value: info.primaries.isEmpty ? "未知" : info.primaries)
                    LabeledContent("位深", value: "\(info.bitDepth)-bit")
                    if info.staticHDRMetadataPresent {
                        if let metadata = info.hdrStaticMetadata {
                            LabeledContent("HDR10 静态元数据", value: "已解析")
                            if let mastering = metadata.masteringDisplay,
                               let maximum = mastering["max_luminance"] {
                                LabeledContent(
                                    "Mastering 峰值",
                                    value: "\(maximum.formatted(.number.precision(.fractionLength(0...3)))) cd/m²"
                                )
                            }
                            if let content = metadata.contentLight {
                                LabeledContent(
                                    "MaxCLL / MaxFALL",
                                    value: "\(content["max_content"] ?? 0) / \(content["max_average"] ?? 0) nit"
                                )
                            }
                            Text("仅 PQ 素材的软件 HEVC 归档可保留并核验这些字段。")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Label("HDR10 静态元数据缺失字段或不一致，禁止无损失保证的转码。", systemImage: "exclamationmark.triangle")
                                .font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Text("支持原版相机 LUT 的 Log → HLG 软件归档和 PQ 静态 HDR10 的软件 HEVC 保留；RAW、动态 HDR 和 Log → SDR 仍需继续移植。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("选择视频后显示格式信息。").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.converting)
    }

    private func samplingLabel(_ choice: SamplingChoice) -> String {
        switch choice {
        case .yuv420: return "4:2:0"
        case .yuv422: return "4:2:2"
        case .yuv444: return "4:4:4"
        case .gray: return "灰度"
        default: return "自动"
        }
    }

    private var presetLabel: String {
        guard model.selection.purpose == .archive else { return "硬件编码" }
        let p = try? RecommendedPresets.software(
            codec: model.selection.codec, fastAV1: model.selection.variant == .fast
                && model.selection.codec == .av1
        )
        return p.map { "\($0.encoder) · \($0.preset) · CRF \($0.quality)" } ?? "预设资源不可用"
    }

    private func isSamplingSupported(_ choice: SamplingChoice) -> Bool {
        guard let media = model.media else { return choice == .yuv420 }
        guard model.selection.purpose == .archive else { return choice == .yuv420 }
        if model.selection.codec == .av1 { return choice == .yuv420 }
        return VideoOutputPolicy.supportedSampling(media).contains(choice.rawValue)
    }

    private func isDepthSupported(_ choice: BitDepthChoice) -> Bool {
        guard let media = model.media, let value = Int(choice.rawValue) else { return choice == .eight }
        return VideoOutputPolicy.supportedDepths(media, selection: model.selection).contains(value)
    }
}
