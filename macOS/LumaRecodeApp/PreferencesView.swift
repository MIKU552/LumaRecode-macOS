import SwiftUI
import UniformTypeIdentifiers
import LumaCore

/// A native macOS Settings scene. FFmpeg is an external dependency: the app
/// never downloads, bundles, or changes the user's installed executables.
struct PreferencesView: View {
    @AppStorage("ffmpegPath") private var ffmpegPath = ""
    @AppStorage("ffprobePath") private var ffprobePath = ""
    @AppStorage("notifyOnComplete") private var notifyOnComplete = true

    @State private var selectingFFmpeg = false
    @State private var selectingFFprobe = false
    @State private var checkingTools = false
    @State private var toolReport: String?

    var body: some View {
        TabView {
            Form {
                Section("外部 FFmpeg") {
                    HStack {
                        TextField("FFmpeg 可执行文件", text: $ffmpegPath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { selectingFFmpeg = true }
                    }
                    HStack {
                        TextField("ffprobe 可执行文件", text: $ffprobePath)
                            .textFieldStyle(.roundedBorder)
                        Button("选择…") { selectingFFprobe = true }
                    }
                    Text("不内嵌 FFmpeg。留空时优先使用 Homebrew ffmpeg-full，再查找 PATH。若只指定 FFmpeg，会优先查找同一目录的 ffprobe。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Link("Homebrew 安装说明 · ffmpeg-full",
                         destination: URL(string: "https://formulae.brew.sh/formula/ffmpeg-full")!)
                        .font(.caption)
                }
                Section("第三方相机 LUT 授权") {
                    if let attribution = try? CameraLogPipeline.openOSVAttributions() {
                        Link("OpenOSV · Apache-2.0 LICENSE", destination: attribution.license)
                        Link("OpenOSV · 原始 NOTICE", destination: attribution.notice)
                    } else {
                        Label("第三方 LUT 声明缺失", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    Text("DJI Pocket 3 LUT 保留 OpenOSV 原始许可；其余四份相机 LUT 使用项目 MIT 许可。FFmpeg 由用户单独安装。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("依赖诊断") {
                    HStack {
                        Button {
                            diagnoseTools()
                        } label: {
                            Label("检测当前媒体工具", systemImage: "checkmark.shield")
                        }
                        .disabled(checkingTools)
                        if checkingTools { ProgressView().controlSize(.small) }
                    }
                    if let toolReport {
                        Text(toolReport)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("媒体工具", systemImage: "gearshape.2") }

            Form {
                Toggle("转换完成时提醒", isOn: $notifyOnComplete)
                Text("外观与文字样式遵循 macOS 系统设置。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "switch.2") }
        }
        .frame(width: 650, height: 380)
        .fileImporter(isPresented: $selectingFFmpeg, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { ffmpegPath = url.path; toolReport = nil }
        }
        .fileImporter(isPresented: $selectingFFprobe, allowedContentTypes: [.item]) { result in
            if case .success(let url) = result { ffprobePath = url.path; toolReport = nil }
        }
    }

    @MainActor
    private func diagnoseTools() {
        guard !checkingTools else { return }
        checkingTools = true
        toolReport = "正在检查外部媒体工具…"
        let encoder = ffmpegPath
        let probe = ffprobePath
        Task { @MainActor in
            defer { checkingTools = false }
            do {
                let tools = try MediaTools.resolve(
                    ffmpeg: encoder.isEmpty ? nil : encoder,
                    ffprobe: probe.isEmpty ? nil : probe
                )
                let caps = try await EncoderCapabilities.discover(tools: tools)
                let software = ["libx264", "libx265", "libsvtav1"]
                    .map { "\($0): \(caps.encoders.contains($0) ? "✓" : "缺失")" }
                    .joined(separator: " · ")
                let vt = ["h264_videotoolbox", "hevc_videotoolbox"]
                    .map { "\($0): \(caps.encoders.contains($0) ? "✓" : "缺失")" }
                    .joined(separator: " · ")
                toolReport = """
                \(caps.version)
                FFmpeg: \(tools.ffmpeg.path)
                ffprobe: \(tools.ffprobe.path)
                软件：\(software)
                VideoToolbox：\(vt)
                zscale：\(caps.filters.contains("zscale") ? "✓ 可用" : "缺失：请使用支持 libzimg 的完整 FFmpeg")
                """
            } catch {
                toolReport = "检查失败：\(error.localizedDescription)"
            }
        }
    }
}
