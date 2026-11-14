import AVKit
import AppKit
import LumaCore
import SwiftUI
import UniformTypeIdentifiers

struct VideoWorkspace: View {
    @EnvironmentObject private var model: WorkspaceModel
    @State private var player = AVPlayer()

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let media = model.media {
                    VideoPlayer(player: player)
                        .background(.black)
                        .overlay(alignment: .topLeading) {
                            Label(media.sourceColor.rawValue.uppercased(), systemImage: "circle.lefthalf.filled")
                                .font(.caption)
                                .padding(8)
                                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                                .padding(12)
                        }
                } else {
                    ContentUnavailableView("尚未选择视频", systemImage: "film.stack",
                        description: Text("通过工具栏添加视频，或将文件拖入窗口。"))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()

            Divider()
            VStack(alignment: .leading, spacing: 12) {
                if let media = model.media {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(media.url.lastPathComponent).font(.headline).lineLimit(1)
                            Text("\(media.codec.uppercased()) · \(media.width)×\(media.height) · \(media.bitDepth)-bit · \(media.sourceColor.rawValue.uppercased())")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(media.duration > 0 ? Duration.seconds(media.duration).formatted() : "未知时长")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    if media.dynamicHDR {
                        Label("动态 HDR 元数据保留尚未移植，因此禁止此素材的转换。", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                    if [.log, .raw, .unknown].contains(media.sourceColor) {
                        Label("当前阶段不对未移植的 Log、RAW 或未知色彩素材进行有损近似处理。", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                } else {
                    Text(model.status).foregroundStyle(.secondary)
                }
                if model.converting {
                    ProgressView(value: model.progress?.fraction ?? 0)
                    HStack {
                        Text(model.status)
                        Spacer()
                        Text("\(Int((model.progress?.fraction ?? 0) * 100))%")
                            .monospacedDigit()
                    }.font(.caption)
                }
                HStack {
                    Label(model.status, systemImage: model.converting ? "gearshape.2" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    if model.converting {
                        Button("取消转换", role: .destructive) { model.cancel() }
                    } else {
                        Button("开始转换") { chooseDestination() }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent)
                            .disabled(model.media == nil || model.loading)
                    }
                }
            }
            .padding(16)
        }
        .onChange(of: model.sourceURL) { newURL in
            player.replaceCurrentItem(with: newURL.map { AVPlayerItem(url: $0) })
        }
    }

    private func chooseDestination() {
        do {
            let suggested = try model.planOutput()
            let panel = NSSavePanel()
            panel.title = "输出视频"
            panel.nameFieldStringValue = suggested.lastPathComponent
            panel.directoryURL = suggested.deletingLastPathComponent()
            panel.canCreateDirectories = true
            panel.allowedContentTypes = [UTType(filenameExtension: suggested.pathExtension) ?? .movie]
            panel.begin { response in
                guard response == .OK, let url = panel.url else { return }
                Task { @MainActor in model.startConversion(to: url) }
            }
        } catch {
            model.present(error)
        }
    }
}
