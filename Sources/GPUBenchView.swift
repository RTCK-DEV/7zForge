import SwiftUI
import Metal

@MainActor @Observable
final class GPUBenchViewModel {
    var fileURL: URL?
    var running = false
    var log = ""
    var gpu: Z7XStats?
    var cpuCompMs = 0.0
    var cpuDecompMs = 0.0
    var cpuSize = 0
    var gpuName = ""
    var errorMsg = ""
    var profile = 1  // 0=爆速 1=バランス 2=最大 3=最適パース(実験)

    private let proc = SevenZipProcess()

    func run() {
        guard let fileURL else { return }
        running = true
        errorMsg = ""
        log = ""
        Task {
            do {
                let attr = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                let fsize = (attr[.size] as? Int) ?? 0
                guard fsize <= GPUCodec.maxInput, fsize > 0 else {
                    errorMsg = "サイズ \(formatBytes(Int64(fsize))) — 1B〜512MB の範囲で"
                    running = false
                    return
                }
                let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
                gpuName = MTLCreateSystemDefaultDevice()?.name ?? "GPU"

                appendLog(">> GPU roundtrip: \(fileURL.lastPathComponent) (\(formatBytes(Int64(fsize))))\n")
                let codec = try GPUCodec()
                let (d, l): (UInt32, UInt32) = [(4, 0), (8, 1), (24, 3), (99, 0)][profile]
                let stats = try await Task.detached { try codec.roundtrip(data, depth: d, lazy: l) }.value
                gpu = stats
                appendLog(String(format: ">> GPU: 圧縮 %.0fms (kernel %.0fms) / 解凍 %.0fms / %.1fx / verify %@\n",
                                 stats.wallCompressMs, stats.gpuCompressMs,
                                 stats.wallDecompressMs, stats.ratio,
                                 stats.verified ? "OK" : "NG"))

                // CPU comparison: 7zz LZMA2 -mx1 all cores (fastest real codec in official 7-Zip)
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("sevenz_bench_\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let cpuOut = tmp.appendingPathComponent("out.7z")
                appendLog(">> CPU: 7zz a -t7z -m0=LZMA2 -mx=1 -mmt=on\n")
                let t0 = CFAbsoluteTimeGetCurrent()
                _ = try await proc.collect(arguments:
                    ["a", "-t7z", "-m0=LZMA2", "-mx=1", "-mmt=on", "-y", cpuOut.path, fileURL.path])
                cpuCompMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
                cpuSize = (try FileManager.default.attributesOfItem(atPath: cpuOut.path)[.size] as? Int) ?? 0

                let dst = tmp.appendingPathComponent("x")
                let t1 = CFAbsoluteTimeGetCurrent()
                _ = try await proc.collect(arguments:
                    ["x", "-y", "-o\(dst.path)", cpuOut.path])
                cpuDecompMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
                appendLog(String(format: ">> CPU: 圧縮 %.0fms / 解凍 %.0fms / %@\n",
                                 cpuCompMs, cpuDecompMs, formatBytes(Int64(cpuSize))))
                try? FileManager.default.removeItem(at: tmp)
            } catch {
                errorMsg = error.localizedDescription
                appendLog(">> ERROR: \(error.localizedDescription)\n")
            }
            running = false
        }
    }

    func appendLog(_ s: String) { log += s }

    var gpuMBps: Double { gpu?.compressMBps ?? 0 }
    var cpuMBps: Double {
        guard cpuCompMs > 0, let g = gpu else { return 0 }
        return Double(g.inputBytes) / 1e6 / (cpuCompMs / 1000)
    }
    var verdict: String {
        guard let g = gpu, cpuCompMs > 0 else { return "" }
        let speedRatio = cpuCompMs / g.wallCompressMs
        let sizeRatio = Double(cpuSize) / Double(g.outputBytes)
        var parts: [String] = []
        parts.append(speedRatio > 1
            ? String(format: "圧縮速度は GPU が %.1fx 速い", speedRatio)
            : String(format: "圧縮速度は CPU が %.1fx 速い", 1 / speedRatio))
        parts.append(sizeRatio > 1
            ? String(format: "圧縮率は CPU が %.1fx 良い", sizeRatio)
            : String(format: "圧縮率は GPU が %.1fx 良い", 1 / sizeRatio))
        if !g.verified { parts.append("WARNING: 往復検証失敗") }
        return parts.joined(separator: " / ")
    }
}

struct GPUBenchView: View {
    @State private var vm = GPUBenchViewModel()
    @State private var showLog = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                GroupBox("Metal GPU 並列コーデック実験 (.z7x 独自フォーマット)") {
                    DropZone { urls in
                        if let u = urls.first(where: { !$0.hasDirectoryPath }) { vm.fileURL = u }
                    } content: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1MB ブロック × 16KB セグメントを GPU スレッドで並列 LZSS + 3ch order-0 rANS。"
                             + "7z 互換ではありません。テストファイルはドロップでも選べます。")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("テストファイル選択…") {
                                vm.fileURL = Panel.chooseFiles(canChooseDirs: false).first
                            }
                            Picker("", selection: $vm.profile) {
                                Text("爆速").tag(0)
                                Text("バランス").tag(1)
                                Text("最大").tag(2)
                                Text("最適パース(実験)").tag(3)
                            }
                            .pickerStyle(.segmented).frame(width: 300)
                            if let f = vm.fileURL {
                                Text(f.lastPathComponent).bold()
                                Text(f.deletingLastPathComponent().path)
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Button(vm.running ? "実行中…" : "比較実行") { vm.run() }
                                .buttonStyle(.borderedProminent)
                                .disabled(vm.fileURL == nil || vm.running)
                        }
                    }
                    .padding(6)
                    }
                }

                if !vm.errorMsg.isEmpty {
                    Text(vm.errorMsg).foregroundStyle(.red)
                }

                if let g = vm.gpu {
                    GroupBox("結果 — \(vm.gpuName)") {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                            GridRow {
                                Text("").frame(width: 110, alignment: .leading)
                                Text("GPU (Z7X)").bold().frame(width: 140, alignment: .trailing)
                                Text("CPU LZMA2-MT").bold().frame(width: 140, alignment: .trailing)
                            }
                            Divider()
                            row("圧縮時間", String(format: "%.0f ms", g.wallCompressMs),
                                String(format: "%.0f ms", vm.cpuCompMs))
                            row("  GPUカーネル", String(format: "%.0f ms", g.gpuCompressMs), "—")
                            row("出力サイズ", formatBytes(Int64(g.outputBytes)),
                                formatBytes(Int64(vm.cpuSize)))
                            row("圧縮率", String(format: "%.2fx", g.ratio),
                                String(format: "%.2fx", Double(g.inputBytes) / max(1, Double(vm.cpuSize))))
                            row("圧縮速度", String(format: "%.0f MB/s", g.compressMBps),
                                String(format: "%.0f MB/s", vm.cpuMBps))
                            row("解凍時間", String(format: "%.0f ms", g.wallDecompressMs),
                                String(format: "%.0f ms", vm.cpuDecompMs))
                            row("解凍速度", String(format: "%.0f MB/s", g.decompressMBps), "—")
                            row("往復検証", g.verified ? "SHA256 ✓" : "✗ NG", "—")
                            row("ブロック", "\(g.blocks) (rANS \(g.ransBlocks) / stored \(g.storedBlocks))", "—")
                        }
                        .padding(6)
                    }
                    Text(vm.verdict).font(.callout).bold()
                }

                DisclosureGroup("ログ", isExpanded: $showLog) {
                    LogView(text: vm.log).frame(minHeight: 120)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    func row(_ label: String, _ gpuV: String, _ cpuV: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(gpuV).monospacedDigit().frame(width: 140, alignment: .trailing)
            Text(cpuV).monospacedDigit().frame(width: 140, alignment: .trailing)
        }
    }
}
