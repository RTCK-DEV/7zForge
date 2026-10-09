import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Auto-scrolling monospace log pane.
struct LogView: View {
    let text: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text.isEmpty ? "(no output)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(6)
                    .id("bottom")
            }
            .onChange(of: text) { _, _ in
                withAnimation(.linear(duration: 0.05)) { proxy.scrollTo("bottom") }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

struct ProgressBar: View {
    let progress: Double
    let running: Bool
    let onCancel: () -> Void
    var body: some View {
        HStack {
            if progress < 0 && running {
                ProgressView().controlSize(.small)
                Text("処理中…").font(.caption).monospacedDigit()
            } else {
                ProgressView(value: progress) {
                    Text(running ? String(format: "%.0f%%", progress * 100) : "待機中")
                        .font(.caption).monospacedDigit()
                }
            }
            if running {
                Button("キャンセル", role: .cancel, action: onCancel)
            }
        }
    }
}

/// Success banner with a "Reveal in Finder" affordance. Shown after a job finishes.
struct ResultBanner: View {
    let title: String
    let url: URL?
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(title).font(.callout).lineLimit(1).truncationMode(.middle)
            Spacer()
            if let url {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Finder で表示", systemImage: "folder")
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Drag & drop target styling: dashed border while hovering a drop.
struct DropZone<Content: View>: View {
    @State private var targeted = false
    let onDropURLs: ([URL]) -> Void
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .foregroundStyle(targeted ? Color.accentColor : Color.clear)
                    .allowsHitTesting(false)
            }
            .background(targeted ? Color.accentColor.opacity(0.08) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                handleDrop(providers) { url in onDropURLs([url]) }
                return true
            }
    }
}

@MainActor enum Panel {
    static func chooseFiles(canChooseDirs: Bool = true) -> [URL] {
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = canChooseDirs
        p.allowsMultipleSelection = true
        return p.runModal() == .OK ? p.urls : []
    }

    static func chooseDirectory() -> URL? {
        let p = NSOpenPanel()
        p.canChooseFiles = false
        p.canChooseDirectories = true
        p.allowsMultipleSelection = false
        return p.runModal() == .OK ? p.url : nil
    }
}

/// Handles dropped file URLs.
func handleDrop(_ providers: [NSItemProvider], add: @escaping @MainActor (URL) -> Void) {
    for item in providers {
        _ = item.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in add(url) }
        }
    }
}

func formatBytes(_ v: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
}
