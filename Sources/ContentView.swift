import SwiftUI

@MainActor @Observable
final class AppState {
    static let shared = AppState()
    var tab = 0
    var pendingFile: URL?
    var pendingCompress: [URL] = []

    static let archiveExts: Set<String> = [
        "7z", "zip", "tar", "gz", "tgz", "bz2", "xz", "zst",
        "rar", "iso", "cab", "wim", "cpio", "z7x",
    ]

    /// ⌘O / File メニューから: アーカイブを選んで解凍タブへ。
    func requestOpenArchive() {
        let urls = Panel.chooseFiles(canChooseDirs: false)
        if let u = urls.first { pendingFile = u; tab = 1 }
    }
}

/// Finder の Quick Actions (NSServices) から呼ばれる。
final class ServiceProvider: NSObject {
    @objc func compressService(_ pb: NSPasteboard, userData: String?,
                               error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pb) { urls in
            AppState.shared.pendingCompress = urls
            AppState.shared.tab = 0
        }
    }
    @objc func extractService(_ pb: NSPasteboard, userData: String?,
                              error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handle(pb) { urls in
            if let u = urls.first {
                AppState.shared.pendingFile = u
                AppState.shared.tab = 1
            }
        }
    }
    private func handle(_ pb: NSPasteboard, _ apply: @escaping @MainActor ([URL]) -> Void) {
        guard let paths = pb.propertyList(forType: .init("NSFilenamesPboardType")) as? [String],
              !paths.isEmpty else { return }
        let urls = paths.map { URL(fileURLWithPath: $0) }
        Task { @MainActor in
            apply(urls)
            NSApp.activate()
        }
    }
}

struct ContentView: View {
    @State private var appState = AppState.shared

    var body: some View {
        TabView(selection: $appState.tab) {
            CompressView()
                .tabItem { Label("圧縮", systemImage: "archivebox") }.tag(0)
            ExtractView()
                .tabItem { Label("解凍 / 一覧", systemImage: "archivebox.fill") }.tag(1)
            BenchmarkView()
                .tabItem { Label("CPUベンチ", systemImage: "speedometer") }.tag(2)
            GPUBenchView()
                .tabItem { Label("GPU実験", systemImage: "gpu") }.tag(3)
        }
        .environment(appState)
        .onOpenURL { url in
            if url.scheme == "z7forge" {
                // FinderSync extension -> z7forge://compress?file=... or z7forge://extract?file=...
                let files = (URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems ?? []).compactMap { $0.name == "file" ? $0.value : nil }
                    .map { URL(fileURLWithPath: $0) }
                if url.host == "compress" {
                    appState.pendingCompress = files
                    appState.tab = 0
                } else if let f = files.first {
                    appState.pendingFile = f
                    appState.tab = 1
                }
            } else {
                appState.pendingFile = url
                appState.tab = 1
            }
        }
        // Global drop routing: archives open in extract, everything else goes
        // to the compress input list. The compress input DropZone still wins
        // for drops made directly inside it (innermost handler).
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers) { url in
                if AppState.archiveExts.contains(url.pathExtension.lowercased()) {
                    appState.pendingFile = url
                    appState.tab = 1
                } else {
                    appState.pendingCompress.append(url)
                    appState.tab = 0
                }
            }
            return true
        }
    }
}
