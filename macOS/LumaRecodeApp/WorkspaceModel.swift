import AppKit
import Observation
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
@Observable
final class WorkspaceModel {
    var area: WorkspaceArea = .video
    var sourceURL: URL?
    var media: MediaInfo?
    var selection = EncodeSelection(purpose: .archive, codec: .hevc)
    var loading = false
    var converting = false
    var progress: TranscodeProgress?
    var errorMessage = ""
    var showError = false
    var status = "选择视频或将文件拖入窗口"
    var jobs: [JobRecord] = []
    var frameTrimEnabled = false
    var frameTimeline: FrameTimeline?
    var trimStartFrame = 1   // User-facing 1-based inclusive.
    var trimEndFrame = 1     // User-facing 1-based inclusive.
    var indexingFrames = false

    @ObservationIgnored private var currentSession: ConversionSession?
    @ObservationIgnored private var securityURL: URL?
    @ObservationIgnored private var loadGeneration = 0

    func open(_ url: URL) {
        loadGeneration += 1
        let generation = loadGeneration
        if let securityURL { securityURL.stopAccessingSecurityScopedResource() }
        let granted = url.startAccessingSecurityScopedResource()
        securityURL = granted ? url : nil
        sourceURL = url
        media = nil
        frameTimeline = nil
        frameTrimEnabled = false
        trimStartFrame = 1
        trimEndFrame = 1
        indexingFrames = false
        loading = true
        progress = nil
        status = "正在分析素材…"
        Task { [self] in
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

    func loadFrameTimeline() {
        guard let media, !indexingFrames, !converting else { return }
        let generation = loadGeneration
        indexingFrames = true
        status = "正在读取原始 PTS 帧索引…"
        Task { [self] in
            do {
                let tools = try resolveTools()
                let timeline = try await FrameTimelineLoader.load(tools: tools, media: media)
                guard generation == loadGeneration else { return }
                frameTimeline = timeline
                trimStartFrame = 1
                trimEndFrame = timeline.count
                status = "已建立 \(timeline.count) 帧的时间轴"
            } catch {
                guard generation == loadGeneration else { return }
                status = "帧索引建立失败"
                present(error)
            }
            if generation == loadGeneration { indexingFrames = false }
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
        let suggestion = EncodingPlanner.destination(
            for: media, selection: selection, directory: media.url.deletingLastPathComponent()
        )
        guard frameTrimEnabled, frameTimeline != nil else { return suggestion }
        let basename = suggestion.deletingPathExtension().lastPathComponent
        return suggestion.deletingLastPathComponent().appendingPathComponent(
            "\(basename)_F\(trimStartFrame)-\(trimEndFrame).\(suggestion.pathExtension)"
        )
    }

    func startConversion(to outputURL: URL) {
        guard !converting, let media else { return }
        guard !frameTrimEnabled || frameTimeline != nil else {
            present(LumaError.invalidInput("请先建立逐帧索引，再开始裁剪。"))
            return
        }
        let selectedTimeline = frameTimeline
        let selectedRange = frameTrimEnabled
            ? FrameRange(start: trimStartFrame - 1, end: trimEndFrame)
            : nil
        converting = true
        progress = nil
        status = "准备转换…"
        let session = ConversionSession()
        currentSession = session
        let chosen = selection
        Task {
            do {
                let tools = try resolveTools()
                let trimmed: TrimmedEncodingPlan?
                let plan: EncodingPlan
                if let selectedTimeline, let selectedRange {
                    let prepared = try FrameTrimPlanner.plan(
                        tools: tools, media: media, selection: chosen,
                        destination: outputURL,
                        timeline: selectedTimeline, range: selectedRange
                    )
                    trimmed = prepared
                    plan = prepared.encoding
                } else {
                    trimmed = nil
                    plan = try EncodingPlanner.plan(
                        tools: tools, media: media, selection: chosen, destination: outputURL
                    )
                }
                status = "正在编码…"
                let output = try await session.execute(
                    plan: plan, tools: tools, source: media,
                    overwrite: FileManager.default.fileExists(atPath: outputURL.path),
                    expectedFrames: trimmed?.window.count,
                    progressDuration: trimmed?.window.duration,
                    onProgress: { [weak self] update in
                        Task { @MainActor in self?.progress = update }
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
