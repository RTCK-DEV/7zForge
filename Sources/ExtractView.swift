import SwiftUI

@MainActor @Observable
final class ExtractViewModel {
    var archive: URL?
    var entries: [ArchiveEntry] = []
    var selection = Set<UUID>()
    var destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var password = ""
    var overwrite = true
    var running = false
    var listing = false
    var progress = 0.0
    var log = ""
    var isZ7X = false
    var lastResult: (title: String, url: URL?)?

    private let proc = SevenZipProcess()

    var selectedEntries: [ArchiveEntry] {
        selection.isEmpty ? entries : entries.filter { selection.contains($0.id) }
    }
    var totalSize: Int64 { entries.reduce(0) { $0 + $1.size } }

    func open() {
        let urls = Panel.chooseFiles(canChooseDirs: false)
        guard let u = urls.first else { return }
        loadArchive(u)
    }

    func loadArchive(_ u: URL) {
        archive = u
        entries = []
        selection = []
        lastResult = nil
        isZ7X = u.pathExtension.lowercased() == "z7x"
        if isZ7X {
            // Single-stream GPU format: show a synthetic entry; decode happens on 解凍.
            let sz = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            entries = [ArchiveEntry(path: u.deletingPathExtension().lastPathComponent,
                                    packedSize: sz)]
            appendLog(">> \(u.lastPathComponent) (z7x GPU 形式) — 解凍先を選んで「解凍」\n")
        } else {
            Task { await list() }
        }
    }

    /// .z7x (GPU codec format): decode to destDir on demand.
    func decodeZ7X() {
        guard let archive else { return }
        running = true
        progress = -1
        lastResult = nil
        appendLog("$ GPU decode \(archive.path)\n")
        let dest = destDir.appendingPathComponent(archive.deletingPathExtension().lastPathComponent)
        Task {
            do {
                let data = try Data(contentsOf: archive, options: .mappedIfSafe)
                let codec = try GPUCodec()
                let (back, ms) = try await Task.detached { try codec.decompress(data) }.value
                try back.write(to: dest)
                appendLog(String(format: ">> GPU 解凍完了 %.0fms → %@\n", ms, dest.path))
                lastResult = ("\(dest.lastPathComponent) に解凍 (\(formatBytes(Int64(back.count))))", dest)
            } catch {
                appendLog(">> z7x 解凍失敗: \(error.localizedDescription)\n")
            }
            running = false
            progress = 0
        }
    }

    func list() async {
        guard let archive else { return }
        listing = true
        entries = []
        appendLog("$ 7zz l -slt \(archive.path)\n")
        do {
            let (status, text) = try await proc.collect(arguments: SevenZip.listArgs(archive: archive, password: password))
            listing = false
            if status == 0 {
                entries = SevenZip.parseListing(text)
                appendLog(">> \(entries.count) エントリ, 合計 \(formatBytes(totalSize))\n")
            } else {
                appendLog(text + "\n>> 一覧失敗 (code \(status)) — パスワードが必要かも\n")
            }
        } catch {
            listing = false
            appendLog(">> \(error.localizedDescription)\n")
        }
    }

    func extract() {
        guard let archive else { return }
        if isZ7X { decodeZ7X(); return }
        lastResult = nil
        let sel = selectedEntries
        let args = SevenZip.extractArgs(archive: archive, dest: destDir,
                                        entries: sel, password: password, overwrite: overwrite)
        running = true
        progress = 0
        appendLog("$ 7zz \(args.joined(separator: " "))\n")
        do {
            try proc.run(arguments: args,
                onLine: { line in Task { @MainActor in self.appendLog(line + "\n") } },
                onProgress: { p in Task { @MainActor in self.progress = p } },
                completion: { status in Task { @MainActor in
                    self.running = false
                    if status == 0 {
                        self.appendLog(">> 解凍完了 → \(self.destDir.path)\n")
                        self.lastResult = ("\(self.destDir.path) に解凍しました", self.destDir)
                    } else {
                        self.appendLog(">> 終了コード \(status)\n")
                    }
                }})
        } catch {
            running = false
            appendLog(">> 起動失敗: \(error.localizedDescription)\n")
        }
    }

    func cancel() { proc.cancel() }

    func appendLog(_ s: String) {
        log += s
        if log.count > 300_000 { log = String(log.suffix(150_000)) }
    }
}

struct ExtractView: View {
    @State private var vm = ExtractViewModel()
    @State private var showLog = false
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("アーカイブを開く…") { vm.open() }
                if let a = vm.archive {
                    Text(a.lastPathComponent).bold()
                    Text(a.deletingLastPathComponent().path)
                        .foregroundStyle(.secondary).font(.caption).lineLimit(1)
                    if !vm.isZ7X {
                        Button { Task { await vm.list() } } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("一覧を再読み込み")
                    }
                }
                Spacer()
                if !vm.isZ7X {
                    SecureField("パスワード", text: $vm.password).frame(width: 160)
                        .onSubmit { Task { await vm.list() } }
                }
            }

            if vm.listing {
                ProgressView("一覧読み込み中…")
            }

            Table(vm.entries, selection: $vm.selection) {
                TableColumn("パス") { e in
                    HStack {
                        Image(systemName: e.isDirectory ? "folder" : "doc")
                        Text(e.path).lineLimit(1).truncationMode(.middle)
                    }
                }
                TableColumn("サイズ") { e in
                    Text(e.isDirectory ? "—" : formatBytes(e.size)).monospacedDigit()
                }.width(90)
                TableColumn("圧縮後") { e in
                    // solid archives don't report per-file packed sizes
                    Text(e.isDirectory || e.packedSize == 0 ? "—" : formatBytes(e.packedSize))
                        .monospacedDigit()
                }.width(90)
                TableColumn("更新日時") { e in
                    Text(e.modified).font(.caption)
                }.width(150)
            }
            .frame(minHeight: 200)
            .overlay {
                if vm.archive == nil {
                    VStack(spacing: 6) {
                        Image(systemName: "archivebox")
                            .font(.largeTitle).foregroundStyle(.tertiary)
                        Text("アーカイブをドラッグ&ドロップ、または ⌘O で開く")
                            .font(.callout).foregroundStyle(.secondary)
                        Text("対応: 7z zip tar gz bz2 xz zst rar iso cab wim cpio z7x")
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                    .allowsHitTesting(false)
                }
            }

            HStack {
                Button("出力先…") { if let u = Panel.chooseDirectory() { vm.destDir = u } }
                Text(vm.destDir.path).foregroundStyle(.secondary).lineLimit(1)
                Picker("", selection: $vm.overwrite) {
                    Text("上書き").tag(true)
                    Text("既存はスキップ").tag(false)
                }
                .pickerStyle(.segmented).frame(width: 200)
            }

            HStack {
                Text(vm.isZ7X ? "z7x → \(vm.destDir.lastPathComponent)/ に展開"
                     : vm.selection.isEmpty
                     ? "全 \(vm.entries.count) 項目を解凍"
                     : "選択 \(vm.selection.count) 項目を解凍")
                    .foregroundStyle(.secondary).font(.caption)
                Spacer()
                Button("解凍") { vm.extract() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.archive == nil || vm.running)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            ProgressBar(progress: vm.progress, running: vm.running) { vm.cancel() }

            if let r = vm.lastResult {
                ResultBanner(title: r.title, url: r.url)
            }

            DisclosureGroup("ログ", isExpanded: $showLog) {
                LogView(text: vm.log).frame(minHeight: 120)
            }
        }
        .padding()
        .onChange(of: appState.pendingFile) { _, url in
            guard let url else { return }
            appState.pendingFile = nil
            vm.loadArchive(url)
        }
        .onAppear {
            guard let url = appState.pendingFile else { return }
            appState.pendingFile = nil
            vm.loadArchive(url)
        }
    }
}
