import SwiftUI
import Charts

@MainActor @Observable
final class BenchViewModel {
    var results: [BenchResult] = []
    var running = false
    var currentStep = ""
    var log = ""

    private let proc = SevenZipProcess()

    var threadChoices: [Int] {
        let n = SevenZip.coreCount
        var s = Set([1, 2, 4, 8, n])
        if n > 4 { s.insert(n / 2) }
        if n > 8 { s.insert((3 * n) / 4) }
        return s.sorted()
    }

    var speedup: [BenchResult] { results.sorted { $0.threads < $1.threads } }
    var singleMIPS: Double { results.first { $0.threads == 1 }?.compressMIPS ?? 0 }

    func runSweep() {
        let choices = threadChoices
        running = true
        results = []
        Task {
            for n in choices {
                currentStep = "スレッド \(n) を計測中… (約15-20秒)"
                appendLog("$ 7zz b -mmt=\(n)\n")
                do {
                    let (status, text) = try await proc.collect(arguments: ["b", "-mmt=\(n)"])
                    if status == 0, let (c, d) = SevenZip.parseBenchTotal(text) {
                        results.append(BenchResult(threads: n, compressMIPS: c, decompressMIPS: d))
                        appendLog(">> threads=\(n)  圧縮 \(Int(c)) MIPS / 解凍 \(Int(d)) MIPS\n")
                    } else {
                        appendLog(text.suffix(500) + "\n>> パース失敗 (code \(status))\n")
                    }
                } catch {
                    appendLog(">> \(error.localizedDescription)\n")
                }
            }
            currentStep = ""
            running = false
            appendLog(">> スイープ完了\n")
        }
    }

    func cancel() { proc.cancel(); running = false }

    func appendLog(_ s: String) {
        log += s
        if log.count > 200_000 { log = String(log.suffix(100_000)) }
    }
}

struct BenchmarkView: View {
    @State private var vm = BenchViewModel()
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading) {
                    Text("CPU: \(SevenZip.coreCount) 論理コア").font(.headline)
                    Text("7zz b (LZMA2 内蔵ベンチ) でスレッド数別の MIPS を計測")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("スレッドスイープ実行") { vm.runSweep() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.running)
                if vm.running { Button("中断") { vm.cancel() } }
            }

            if vm.running {
                ProgressView().controlSize(.small)
                Text(vm.currentStep).font(.caption).foregroundStyle(.secondary)
            }

            if !vm.speedup.isEmpty {
                Chart(vm.speedup) { r in
                    BarMark(x: .value("Threads", String(r.threads)),
                            y: .value("MIPS", r.compressMIPS))
                    .foregroundStyle(.blue.gradient)
                    LineMark(x: .value("Threads", String(r.threads)),
                             y: .value("理想", vm.singleMIPS * Double(r.threads)),
                             series: .value("s", "ideal"))
                    .foregroundStyle(.orange).lineStyle(StrokeStyle(dash: [4]))
                }
                .chartYAxisLabel("圧縮 MIPS")
                .frame(minHeight: 200)

                Chart(vm.speedup) { r in
                    BarMark(x: .value("Threads", String(r.threads)),
                            y: .value("MIPS", r.decompressMIPS))
                    .foregroundStyle(.green.gradient)
                }
                .chartYAxisLabel("解凍 MIPS")
                .frame(minHeight: 160)
            }

            DisclosureGroup("ログ", isExpanded: $showLog) {
                LogView(text: vm.log).frame(minHeight: 140)
            }
            Spacer()
        }
        .padding()
    }
}
