import LumaCore
import SwiftUI

struct EncodingInspector: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        Form {
            Section("用途") {
                Picker("模式", selection: $model.selection.purpose) {
                    Text("软件归档").tag(EncodePurpose.archive)
                    Text("快速分享").tag(EncodePurpose.share)
                }
                .pickerStyle(.segmented)
                Text(model.selection.purpose == .archive
                     ? "使用与 Windows 版相同的软件编码预设。"
                     : "使用 Apple VideoToolbox 硬件编码，质量预设来自公开参考数据。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("编码") {
                Picker("视频格式", selection: $model.selection.codec) {
                    ForEach(VideoCodec.allCases) { codec in
                        if model.selection.purpose == .archive || codec != .av1 {
                            Text(codec.title).tag(codec)
                        }
                    }
                }
                .onChange(of: model.selection.purpose) { purpose in
                    if purpose == .share && model.selection.codec == .av1 {
                        model.selection.codec = .hevc
                    }
                }
                if model.selection.purpose == .archive {
                    LabeledContent("编码模式", value: "软件")
                    LabeledContent("预设", value: presetLabel)
                } else {
                    LabeledContent("编码模式", value: "VideoToolbox")
                    LabeledContent("质量参考", value: model.selection.codec == .hevc ? "65" : "70")
                }
            }
            Section("色彩") {
                if let info = model.media {
                    LabeledContent("输入", value: info.sourceColor.rawValue.uppercased())
                    LabeledContent("传递函数", value: info.transfer.isEmpty ? "未知" : info.transfer)
                    LabeledContent("色域", value: info.primaries.isEmpty ? "未知" : info.primaries)
                    LabeledContent("位深", value: "\(info.bitDepth)-bit")
                    Text("当前阶段仅支持已识别的 SDR 和静态 HLG/PQ 转码；保留原始传递函数，不提供尚未验证的色彩转换。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("选择素材后显示色彩信息。").foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.converting)
    }

    private var presetLabel: String {
        switch model.selection.codec {
        case .hevc: return "x265 medium · CRF 23"
        case .avc: return "x264 medium · CRF 21"
        case .av1: return "SVT-AV1 preset 4 · CRF 32"
        }
    }
}
