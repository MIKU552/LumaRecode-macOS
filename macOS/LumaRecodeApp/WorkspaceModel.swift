import AppKit
import Combine
import Foundation
import LumaCore

enum WorkspaceArea: String, Hashable, CaseIterable, Identifiable {
    case video, photos, jobs
    var id: String { rawValue }
    var label: String {
        switch self {
        case .video: return "视频转换"
        case .photos: return "照片导出"
        case .jobs: return "任务历史"
        }
    }
    var symbol: String {
        switch self {
        case .video: return "film.stack"
        case .photos: return "photo.on.rectangle"
        case .jobs: return "clock.arrow.circlepath"
        }
    }
}

struct JobRecord: Identifiable {
    enum Outcome { case success, failed, cancelled }
    let id = UUID()
    let date = Date()
    let name: String
    let outcome: Outcome
    let detail: String
    let fileURL: URL?
}

@MainActor
final class WorkspaceModel: ObservableObject {
    @Published var area: WorkspaceArea = .video
    @Published var sourceURL: URL?
    @Published var media: MediaInfo?
    @Published var selection = EncodeSelection(purpose: .archive, codec: .hevc)
    @Published var loading = false
    @Published var converting = false
    @Published var progress: TranscodeProgress?
    @Published var errorMessage = ""
    @Published var showError = false
    @Published var status = "选择视频或将文件拖入窗口"
    @Published var jobs: [JobRecord] = []

    private var currentSession: ConversionSession?
    private var securityURL: URL?
    private var loadGeneration = 0

    func open(_ url: URL) {
        loadGeneration += 1
        let generation = loadGeneration
        if let securityURL { securityURL.stopAccessingSecurityScopedResource() }
        let granted = url.startAccessingSecurityScopedResource()
        securityURL = granted ? url : nil
        sourceURL = url
        media = nil
        loading = true
        progress = nil
        status = "正在分析素材…"
        Task {
            do {
                let tools = try resolveTools()
                let result = try await MediaProbe.inspect(tools: tools, url: url)
                guard generation == self.loadGeneration else { return }
                media = result
                status = "已读取 \(result.codec.uppercased()) · \(result.width)×\(result.height)"
            } catch {
                guard generation == self.loadGeneration else { return }
                status = "素材读取失败"
                present(error)
            }
            if generation == self.loadGeneration { loading = false }
        }
    }

    func resolveTools() throws -> MediaTools {
        let defaults = UserDefaults.standard
        return try MediaTools.resolve(
            ffmpeg: defaults.string(forKey: "ffmpegPath"),
            ffprobe: defaults.string(forKey: "ffprobePath")
        )
    }

    func planOutput() throws -> URL {
        guard let media else { throw LumaError.invalidInput("Choose a source video first.") }
        return EncodingPlanner.destination(
            for: media, selection: selection, directory: media.url.deletingLastPathComponent()
        )
    }

    func startConversion(to outputURL: URL) {
        guard !converting, let media else { return }
        converting = true
        progress = nil
        status = "准备转换…"
        let session = ConversionSession()
        currentSession = session
        let chosen = selection
        Task {
            do {
                let tools = try resolveTools()
                let plan = try EncodingPlanner.plan(
                    tools: tools, media: media, selection: chosen, destination: outputURL
                )
                status = "正在编码…"
                let output = try await session.execute(
                    plan: plan, tools: tools, source: media,
                    overwrite: FileManager.default.fileExists(atPath: outputURL.path),
                    onProgress: { [weak self] update in
                        Task { @MainActor [weak self] in self?.progress = update }
                    }
                )
                status = "转换完成"
                progress = TranscodeProgress(seconds: 1, duration: 1, fps: nil)
                jobs.insert(JobRecord(name: media.url.lastPathComponent, outcome: .success,
                                      detail: "已保存至 \(output.lastPathComponent)", fileURL: output), at: 0)
                if UserDefaults.standard.object(forKey: "notifyOnComplete") as? Bool ?? true {
                    NSSound.beep()
                }
            } catch {
                status = "任务结束"
                if case LumaError.cancelled = error {
                    jobs.insert(JobRecord(name: media.url.lastPathComponent, outcome: .cancelled,
                                          detail: "已取消", fileURL: nil), at: 0)
                } else {
                    jobs.insert(JobRecord(name: media.url.lastPathComponent, outcome: .failed,
                                          detail: error.localizedDescription, fileURL: nil), at: 0)
                    present(error)
                }
            }
            currentSession = nil
            converting = false
        }
    }

    func cancel() {
        currentSession?.cancel()
        status = "正在取消…"
    }

    func present(_ error: Error) {
        errorMessage = error.localizedDescription
        showError = true
    }
}
