import AppKit
import LumaCore
import SwiftUI

struct PhotoWorkspace: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var seconds = 0.0
    @State private var format: StillFormat = .heic
    @State private var quality = 0.95
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("照片导出")
                .font(.largeTitle)
                .fontWeight(.semibold)
            if let media = model.media {
                LabeledContent("当前素材", value: media.url.lastPathComponent)
                LabeledContent("色彩类型", value: media.sourceColor.rawValue.uppercased())
                if media.sourceColor == .sdr {
                    Form {
                        HStack {
                            Slider(value: $seconds, in: 0...max(0.001, media.duration), step: 0.1)
                            Text(String(format: "%.1f 秒", seconds))
                                .monospacedDigit().frame(width: 100)
                        }
                        Picker("格式", selection: $format) {
                            ForEach(StillFormat.allCases) { f in
                                Text(f.label).tag(f)
                            }
                        }
                        Slider(value: $quality, in: 0.1...1, step: 0.05) {
                            Text("质量")
                        }
                        Button(exporting ? "正在导出…" : "导出静态照片") {
                            chooseDestination(source: media.url)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(exporting)
                    }
                    .formStyle(.grouped)
                    Text("静态帧通过 AVFoundation 和 ImageIO 输出。此阶段仅启用已识别 SDR 输入。")
                        .foregroundStyle(.secondary).font(.callout)
                } else {
                    ContentUnavailableView("HDR / Log 照片导出尚未完成",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("10-bit HDR HEIC、Gain Map 和 Live Photo 将使用 Apple 原生照片 API。当前不会使用 SDR 截帧伪装 HDR。"))
                }
            } else {
                ContentUnavailableView("先选择视频", systemImage: "photo.on.rectangle",
                    description: Text("点击工具栏中的添加视频，再从素材中导出照片。"))
            }
            Spacer()
        }
        .padding(24)
        .onChange(of: model.sourceURL) { _ in seconds = 0 }
    }

    private func chooseDestination(source: URL) {
        let panel = NSSavePanel()
        panel.title = "导出照片"
        panel.nameFieldStringValue = source.deletingPathExtension().lastPathComponent
            + "_\(Int(seconds * 1000)).\(format.rawValue)"
        panel.directoryURL = source.deletingLastPathComponent()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [format.type]
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                exporting = true
                defer { exporting = false }
                do {
                    try await StillExporter.export(
                        source: source, to: url, seconds: seconds, format: format, quality: quality
                    )
                    model.jobs.insert(JobRecord(
                        name: source.lastPathComponent, outcome: .success,
                        detail: "照片已保存至 \(url.lastPathComponent)", fileURL: url
                    ), at: 0)
                } catch {
                    model.present(error)
                }
            }
        }
    }
}
