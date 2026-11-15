import LumaCore
import SwiftUI

/// Native macOS inspector: choices follow source capabilities; original preset
/// data is read by the Swift core, not hard-coded as WinUI screen values.
struct EncodingInspector: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
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
                    if purpose == .share {
                        if model.selection.codec == .av1 { model.selection.codec = .hevc }
                        model.selection.variant = .standard
                    }
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
            Section("格式") {
                Picker("色度采样", selection: $model.selection.sampling) {
                    Text("自动").tag(SamplingChoice.automatic)
                    Text("保持原片").tag(SamplingChoice.source)
                    ForEach([SamplingChoice.yuv420, .yuv422, .yuv444, .gray]) { format in
                        if isSamplingSupported(format) {
                            Text(format == .gray ? "灰度" : "4:\(String(format.rawValue.dropFirst()))")
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
            Section("输入色彩") {
                if let info = model.media {
                    LabeledContent("类别", value: info.sourceColor.rawValue.uppercased())
                    LabeledContent("传递函数", value: info.transfer.isEmpty ? "未知" : info.transfer)
                    LabeledContent("色域", value: info.primaries.isEmpty ? "未知" : info.primaries)
                    LabeledContent("位深", value: "\(info.bitDepth)-bit")
                    Text("Log、RAW 和动态 HDR 的完整处理尚待移植，当前不进行有损近似转换。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("选择视频后显示格式信息。").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.converting)
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
