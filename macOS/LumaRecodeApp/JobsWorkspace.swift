import AppKit
import SwiftUI

struct JobsWorkspace: View {
    @EnvironmentObject private var model: WorkspaceModel

    var body: some View {
        if model.jobs.isEmpty {
            ContentUnavailableView("尚无任务", systemImage: "clock.arrow.circlepath",
                                   description: Text("完成的视频转码会显示在这里。"))
        } else {
            List(model.jobs) { job in
                HStack(spacing: 12) {
                    Image(systemName: symbol(for: job.outcome))
                        .foregroundStyle(color(for: job.outcome))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(job.name).font(.headline)
                        Text(job.detail).foregroundStyle(.secondary).font(.caption)
                        Text(job.date, style: .date).foregroundStyle(.tertiary).font(.caption2)
                    }
                    Spacer()
                    if let url = job.fileURL {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func symbol(for outcome: JobRecord.Outcome) -> String {
        switch outcome {
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle.fill"
        }
    }
    private func color(for outcome: JobRecord.Outcome) -> Color {
        switch outcome {
        case .success: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }
}
