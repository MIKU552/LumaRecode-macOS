import SwiftUI

struct PreferencesView: View {
    @AppStorage("ffmpegPath") private var ffmpegPath = ""
    @AppStorage("ffprobePath") private var ffprobePath = ""
    @AppStorage("notifyOnComplete") private var notifyOnComplete = true

    var body: some View {
        TabView {
            Form {
                TextField("FFmpeg 可执行文件", text: $ffmpegPath)
                TextField("ffprobe 可执行文件", text: $ffprobePath)
                Text("留空时自动搜索 PATH、/opt/homebrew/bin 和 /usr/local/bin。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 590, height: 300)
    }
}
