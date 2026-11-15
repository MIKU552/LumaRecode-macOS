import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(WorkspaceModel.self) private var model
    @State private var importing = false
    @State private var inspectorVisible = true
    @State private var playerWarning = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $model.area) {
                Section("工作区") {
                    ForEach(WorkspaceArea.allCases) { area in
                        Label(area.label, systemImage: area.symbol)
                            .tag(area)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 165, ideal: 190, max: 250)
        } detail: {
            Group {
                switch model.area {
                case .video: VideoWorkspace()
                case .photos: PhotoWorkspace()
                case .jobs: JobsWorkspace()
                }
            }
            .navigationTitle(model.area.label)
            .inspector(isPresented: $inspectorVisible) {
                EncodingInspector()
                    .inspectorColumnWidth(min: 250, ideal: 290, max: 340)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    importing = true
                } label: {
                    Label("添加视频", systemImage: "plus")
                }
                .help("Import a video")
                .disabled(model.converting)
            }
            ToolbarItem {
                Button {
                    inspectorVisible.toggle()
                } label: {
                    Label("检查器", systemImage: "sidebar.right")
                }
                .help("Show or hide encoding inspector")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
            switch result {
            case .success(let url):
                self.model.open(url)
                self.model.area = .video
            case .failure(let error):
                self.model.present(error)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            // Capture the reference, not the mutable @Bindable projection,
            // across NSItemProvider's completion callback.
            let workspace = self.model
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in workspace.open(url) }
            }
            return true
        }
        .alert("操作无法完成", isPresented: $model.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(model.errorMessage)
        }
    }
}
