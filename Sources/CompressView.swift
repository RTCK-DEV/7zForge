import SwiftUI

@MainActor @Observable
final class CompressViewModel {
    var inputs: [URL] = []
    var archiveName = "archive"
    var destDir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    var options = CompressOptions()
    var running = false
    var progress = 0.0
    var log = ""
    var lastStatus: Int32?
    var lastResult: (title: String, url: URL?)?
    var nameTouched = false

    private let proc = SevenZipProcess()

    var archiveURL: URL {
        destDir.appendingPathComponent(archiveName.isEmpty ? "archive" : archiveName)
            .appendingPathExtension(options.format.rawValue)
    }
    var canRun: Bool { !inputs.isEmpty && !running }

    func applyFastPreset() {
        options.format = .sevenZ
        options.codec = .lzma2
        options.level = 1
        options.threads = 0
        options.solid = false
        options.dictMB = 0
        appendLog(">> 爆速プリセット: LZMA2 mx1, mmt=全\(SevenZip.coreCount)コア, non-solid\n")
        appendLog("   (公式7-ZipはZstd圧縮非対応 — 実在する最速構成はこれ)\n")
    }

    func applyMaxPreset() {
        options.format = .sevenZ
        options.codec = .lzma2
        options.level = 9
        options.threads = 0
        options.solid = true
        options.dictMB = 192
        appendLog(">> 最高圧縮プリセット: LZMA2 mx9, dict=192MB, solid\n")
    }

    /// Append inputs (dedup) and auto-suggest the archive name from the first input
    /// as long as the user hasn't typed a custom name.
    func addInputs(_ urls: [URL]) {
        let fresh = urls.filter { !inputs.contains($0) }
        guard !fresh.isEmpty else { return }
        inputs += fresh
        if !nameTouched, let first = fresh.first {
            let base = first.deletingPathExtension().lastPathComponent
            if !base.isEmpty { archiveName = base }
        }
    }

    func run() {
        if options.format.isGPU { runZ7X(); return }
        let args = SevenZip.compressArgs(options, archive: archiveURL, inputs: inputs)
        let out = archiveURL
        running = true
        progress = 0
        lastStatus = nil
        lastResult = nil
        appendLog("$ 7zz \(args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " "))\n")
        do {
            try proc.run(arguments: args,
                onLine: { line in Task { @MainActor in self.appendLog(line + "\n") } },
                onProgress: { p in Task { @MainActor in self.progress = p } },
                completion: { status in Task { @MainActor in
                    self.running = false
                    self.lastStatus = status
                    if status == 0 {
                        self.appendLog(">> 完了\n")
                        let sz = (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                        self.lastResult = ("\(out.lastPathComponent) を作成 (\(formatBytes(sz)))", out)
                    } else {
                        self.appendLog(">> 終了コード \(status)\n")
                    }
                }})
        } catch {
            running = false
            appendLog(">> 起動失敗: \(error.localizedDescription)\n")
        }
    }

    /// .z7x: single-stream GPU codec — inputs are concatenated into one stream.
    func runZ7X() {
        running = true
        progress = -1
        lastStatus = nil
        lastResult = nil
        let out = archiveURL
        let (d, l): (UInt32, UInt32) = [(4, 0), (8, 1), (24, 3), (99, 0)][options.gpuProfile]
        if inputs.count > 1 {
            appendLog(">> 注意: z7x は単一ストリーム形式 — \(inputs.count) ファイルを結合します\n")
        }
        appendLog("$ GPU z7x compress → \(out.path) (depth=\(d) lazy=\(l))\n")
        Task {
            do {
                var data = Data()
                for u in inputs {
                    guard !u.hasDirectoryPath else { throw GPUError.badInput }
                    data.append(try Data(contentsOf: u, options: .mappedIfSafe))
                }
                guard !data.isEmpty else { throw GPUError.badInput }
                let input = data
                let codec = try GPUCodec()
                let t0 = CFAbsoluteTimeGetCurrent()
                let r = try await Task.detached {
                    let t = try codec.compress(input, depth: d, lazy: l)
                    return Z7XCompressed(file: t.file, gpuMs: t.gpuMs)
                }.value
                let wallMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                try r.file.write(to: out)
                appendLog(String(format: ">> 完了 %.0fms (kernel %.0fms) %@ → %@ (%.2fx)\n",
                                 wallMs, r.gpuMs,
                                 formatBytes(Int64(data.count)), formatBytes(Int64(r.file.count)),
                                 Double(data.count) / Double(r.file.count)))
                lastResult = ("\(out.lastPathComponent) を作成 (\(formatBytes(Int64(r.file.count))))", out)
            } catch {
                appendLog(">> z7x 圧縮失敗: \(error.localizedDescription)\n")
            }
            running = false
            progress = 0
        }
    }

    func cancel() { proc.cancel() }

    func appendLog(_ s: String) {
        log += s
        if log.count > 300_000 { log = String(log.suffix(150_000)) }
    }
}

struct CompressView: View {
    @State private var vm = CompressViewModel()
    @State private var showLog = false
    @Environment(AppState.self) private var appState

    private func takePending() {
        let urls = appState.pendingCompress
        guard !urls.isEmpty else { return }
        appState.pendingCompress = []
        vm.addInputs(urls)
        vm.appendLog(">> Finder から \(urls.count) 項目を追加\n")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("入力") {
                    DropZone { urls in
                        let (archives, files) = urls.reduce(into: ([URL](), [URL]())) {
                            if AppState.archiveExts.contains($1.pathExtension.lowercased()) {
                                $0.0.append($1)
                            } else {
                                $0.1.append($1)
                            }
                        }
                        vm.addInputs(files)
                        if let a = archives.first {
                            appState.pendingFile = a
                            appState.tab = 1
                        }
                    } content: {
                        VStack(alignment: .leading, spacing: 6) {
                            List {
                                ForEach(vm.inputs, id: \.self) { url in
                                    InputRow(url: url) { vm.inputs.removeAll { $0 == url } }
                                }
                                .onDelete { vm.inputs.remove(atOffsets: $0) }
                            }
                            .frame(minHeight: 90, maxHeight: 140)
                            .overlay {
                                if vm.inputs.isEmpty {
                                    VStack(spacing: 4) {
                                        Image(systemName: "arrow.down.doc")
                                            .font(.title2).foregroundStyle(.tertiary)
                                        Text("ここにファイル / フォルダをドロップ")
                                            .font(.callout).foregroundStyle(.secondary)
                                    }
                                    .allowsHitTesting(false)
                                }
                            }
                            HStack {
                                Button("ファイル追加") { vm.addInputs(Panel.chooseFiles(canChooseDirs: false)) }
                                Button("フォルダ追加") { if let u = Panel.chooseDirectory() { vm.addInputs([u]) } }
                                Spacer()
                                Button("クリア") { vm.inputs.removeAll() }
                                    .disabled(vm.inputs.isEmpty)
                            }
                        }
                        .padding(6)
                    }
                }

                GroupBox("出力") {
                    HStack {
                        Button("保存先…") { if let u = Panel.chooseDirectory() { vm.destDir = u } }
                        Text(vm.destDir.path).foregroundStyle(.secondary).lineLimit(1)
                        TextField("名前", text: Binding(
                            get: { vm.archiveName },
                            set: { vm.nameTouched = true; vm.archiveName = $0 }))
                            .frame(width: 180)
                        Text(".\(vm.options.format.rawValue)").foregroundStyle(.secondary)
                    }
                    .padding(6)
                }

                GroupBox("設定") {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("形式")
                            Picker("", selection: $vm.options.format) {
                                ForEach(SZFormat.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented).frame(width: 190)
                            .onChange(of: vm.options.format) { _, f in
                                if !f.codecs.contains(vm.options.codec) { vm.options.codec = f.codecs[0] }
                            }
                            if !vm.options.format.isGPU {
                                Text("コーデック")
                                Picker("", selection: $vm.options.codec) {
                                    ForEach(vm.options.format.codecs) {
                                        Text("\($0.rawValue) — \($0.note)").tag($0)
                                    }
                                }
                            } else {
                                Text("プロファイル")
                                Picker("", selection: $vm.options.gpuProfile) {
                                    Text("爆速").tag(0)
                                    Text("バランス").tag(1)
                                    Text("最大").tag(2)
                                }
                                .pickerStyle(.segmented).frame(width: 200)
                            }
                        }
                        if !vm.options.format.isGPU {
                            GridRow {
                                Text("レベル")
                                HStack {
                                    Slider(value: .convert($vm.options.level), in: 0...9, step: 1)
                                    Text("mx\(vm.options.level)").monospacedDigit().frame(width: 36)
                                }
                                Text("スレッド")
                                HStack {
                                    Stepper(value: $vm.options.threads, in: 0...SevenZip.coreCount) {
                                        Text(vm.options.threads == 0 ? "全\(SevenZip.coreCount)コア" : "\(vm.options.threads)")
                                    }
                                }
                            }
                            GridRow {
                                Text("辞書")
                                Picker("", selection: $vm.options.dictMB) {
                                    Text("自動").tag(0)
                                    ForEach([16, 32, 64, 96, 128, 192, 256], id: \.self) {
                                        Text("\($0)MB").tag($0)
                                    }
                                }
                                .disabled(!vm.options.codec.supportsDict)
                                Toggle("ソリッド", isOn: $vm.options.solid)
                                    .disabled(vm.options.format != .sevenZ)
                            }
                            GridRow {
                                Text("パスワード")
                                SecureField("空欄=暗号化なし", text: $vm.options.password)
                                Toggle("ヘッダも暗号化", isOn: $vm.options.headerEncrypt)
                                    .disabled(vm.options.format != .sevenZ)
                            }
                        } else {
                            GridRow {
                                Text("")
                                Text("z7x は実験的な GPU 専用単一ストリーム形式です。暗号化・複数ファイル構造なし。対象は 1B〜512MB。")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .gridCellColumns(3)
                            }
                        }
                    }
                    .padding(6)
                }

                HStack {
                    Button("爆速 LZMA2") { vm.applyFastPreset() }
                    Button("最高圧縮 LZMA2") { vm.applyMaxPreset() }
                    Spacer()
                    Button(vm.running ? "実行中…" : "圧縮開始") { vm.run() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!vm.canRun)
                        .keyboardShortcut(.return, modifiers: .command)
                }

                ProgressBar(progress: vm.progress, running: vm.running) { vm.cancel() }

                if let r = vm.lastResult {
                    ResultBanner(title: r.title, url: r.url)
                }

                DisclosureGroup("ログ", isExpanded: $showLog) {
                    LogView(text: vm.log).frame(minHeight: 140)
                }
            }
            .padding()
        }
        .onChange(of: appState.pendingCompress) { _, _ in takePending() }
        .onAppear { takePending() }
    }
}

/// Input list row: icon, name, size, path, and a delete button on hover.
struct InputRow: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    private var sizeString: String {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        return (v?.isDirectory == false) ? formatBytes(Int64(v?.fileSize ?? 0)) : "—"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: url.hasDirectoryPath ? "folder" : "doc")
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent).lineLimit(1)
            Spacer()
            Text(sizeString)
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            Text(url.deletingLastPathComponent().path)
                .foregroundStyle(.tertiary).font(.caption)
                .lineLimit(1).truncationMode(.head)
            Button { onRemove() } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .opacity(hovering ? 1 : 0)
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Finder で表示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("リストから削除", role: .destructive) { onRemove() }
        }
    }
}

private extension Binding where Value == Double {
    static func convert(_ b: Binding<Int>) -> Binding<Double> {
        Binding<Double>(get: { Double(b.wrappedValue) }, set: { b.wrappedValue = Int($0) })
    }
}
