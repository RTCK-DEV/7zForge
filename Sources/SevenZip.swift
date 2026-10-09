import Foundation

enum SevenZipError: Error, LocalizedError {
    case binaryNotFound
    var errorDescription: String? { "7zz バイナリが見つかりません" }
}

enum SZFormat: String, CaseIterable, Identifiable {
    case sevenZ = "7z"
    case zip = "zip"
    case z7x = "z7x"
    var id: String { rawValue }
    var codecs: [SZCodec] {
        switch self {
        case .sevenZ: [.lzma2, .lzma, .ppmd, .bzip2, .deflate, .copy]
        case .zip:    [.deflate, .deflate64, .bzip2, .lzma]
        case .z7x:   [.gpu]
        }
    }
    var isGPU: Bool { self == .z7x }
}

enum SZCodec: String, CaseIterable, Identifiable {
    case lzma2 = "LZMA2"
    case lzma = "LZMA"
    case ppmd = "PPMd"
    case bzip2 = "BZip2"
    case deflate = "Deflate"
    case deflate64 = "Deflate64"
    case copy = "Copy"
    case gpu = "Z7X-GPU"
    var id: String { rawValue }
    var method: String { rawValue }
    var supportsDict: Bool { self == .lzma2 || self == .lzma }
    var note: String {
        switch self {
        case .lzma2: "最高圧縮率・MT可・標準"
        case .lzma: "旧式・単独ブロック"
        case .ppmd: "テキストに強い・低速"
        case .bzip2: "中間"
        case .deflate: "zip 互換・高速"
        case .deflate64: "zip・やや高圧縮"
        case .copy: "無圧縮・格納のみ"
        case .gpu: "Metal 並列・実験フォーマット"
        }
    }
}

struct CompressOptions {
    var format: SZFormat = .sevenZ
    var codec: SZCodec = .lzma2
    var level: Int = 5            // -mx (0-9)
    var threads: Int = 0          // 0 = all cores
    var dictMB: Int = 0           // 0 = codec default
    var solid: Bool = true
    var password = ""
    var headerEncrypt = true
    var gpuProfile: Int = 1      // z7x: 0=爆速 1=バランス 2=最大 3=DP実験
}

struct ArchiveEntry: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var size: Int64 = 0
    var packedSize: Int64 = 0
    var modified = ""
    var isDirectory = false
}

struct BenchResult: Identifiable {
    var id: Int { threads }
    var threads: Int
    var compressMIPS: Double
    var decompressMIPS: Double
}

enum SevenZip {
    static var executableURL: URL? {
        if let u = Bundle.main.url(forResource: "7zz", withExtension: nil),
           FileManager.default.isExecutableFile(atPath: u.path) { return u }
        for p in ["/opt/homebrew/bin/7zz", "/usr/local/bin/7zz"] {
            if FileManager.default.isExecutableFile(atPath: p) {
                return URL(fileURLWithPath: p)
            }
        }
        return nil
    }

    static var coreCount: Int { ProcessInfo.processInfo.processorCount }

    static func compressArgs(_ o: CompressOptions, archive: URL, inputs: [URL]) -> [String] {
        var a = ["a", "-bsp1", "-y", "-t\(o.format.rawValue)", "-mx=\(o.level)"]
        a.append("-m0=\(o.codec.method)")
        if o.dictMB > 0, o.codec.supportsDict { a.append("-md\(o.dictMB)m") }
        a.append(o.threads > 0 ? "-mmt=\(o.threads)" : "-mmt=on")
        if o.format == .sevenZ { a.append(o.solid ? "-ms=on" : "-ms=off") }
        if !o.password.isEmpty {
            a.append("-p\(o.password)")
            if o.headerEncrypt, o.format == .sevenZ { a.append("-mhe=on") }
        }
        a.append(archive.path)
        a.append(contentsOf: inputs.map(\.path))
        return a
    }

    static func extractArgs(archive: URL, dest: URL, entries: [ArchiveEntry], password: String, overwrite: Bool) -> [String] {
        var a = ["x", "-bsp1", "-y", archive.path, "-o\(dest.path)"]
        if overwrite { a.append("-aoa") } else { a.append("-aos") }
        if !password.isEmpty { a.append("-p\(password)") }
        a.append(contentsOf: entries.map(\.path))
        return a
    }

    static func listArgs(archive: URL, password: String) -> [String] {
        var a = ["l", "-slt", archive.path]
        if !password.isEmpty { a.append("-p\(password)") }
        return a
    }

    /// Parse `7zz l -slt` output into file entries (first block = archive info, skipped).
    static func parseListing(_ text: String) -> [ArchiveEntry] {
        var entries: [ArchiveEntry] = []
        var cur: [String: String] = [:]
        func flush() {
            guard let path = cur["Path"], cur["Physical Size"] == nil else { cur = [:]; return }
            var e = ArchiveEntry(path: path)
            e.size = Int64(cur["Size"] ?? "") ?? 0
            e.packedSize = Int64(cur["Packed Size"] ?? "") ?? 0
            e.modified = cur["Modified"] ?? ""
            e.isDirectory = (cur["Folder"] == "+")
            entries.append(e)
            cur = [:]
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.allSatisfy({ $0 == "-" }) { flush(); continue }
            if let r = line.range(of: " = ") {
                let key = String(line[line.startIndex..<r.lowerBound])
                // A new "Path =" with a block still open means the next entry begins
                // (entries are separated only by blank lines).
                if key == "Path" && cur["Path"] != nil { flush() }
                cur[key] = String(line[r.upperBound...])
            }
        }
        flush()
        return entries
    }

    /// Parse `7zz b` output -> (compress MIPS, decompress MIPS).
    /// The `Avr:` line carries both sides ("|"-separated); `Tot:` merges to one grand average.
    static func parseBenchTotal(_ text: String) -> (Double, Double)? {
        var tot: Double?
        for raw in text.split(separator: "\n").reversed() {
            let s = raw.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("Avr:") {
                let sides = s.dropFirst(4).components(separatedBy: "|")
                if sides.count >= 2,
                   let c = lastNumber(sides[0]), let d = lastNumber(sides[1]) {
                    return (c, d)
                }
            } else if s.hasPrefix("Tot:") {
                tot = lastNumber(String(s.dropFirst(4)))
            }
        }
        if let tot { return (tot, tot) }
        return nil
    }

    private static func lastNumber(_ s: String) -> Double? {
        s.split(whereSeparator: \.isWhitespace).compactMap { Double($0) }.last
    }
}

/// Byte-stream -> line splitter that handles both \n and \r (7zz progress uses \r-ish updates).
final class LinePump: @unchecked Sendable {
    private var buf = [UInt8]()
    private let lock = NSLock()
    private let handler: @Sendable (String) -> Void
    init(handler: @escaping @Sendable (String) -> Void) { self.handler = handler }

    func feed(_ d: Data) {
        lock.lock()
        buf.append(contentsOf: d)
        var lines: [String] = []
        var start = 0
        for i in 0..<buf.count where buf[i] == 0x0A || buf[i] == 0x0D {
            if i > start {
                if let s = String(bytes: buf[start..<i], encoding: .utf8) { lines.append(s) }
            } else if buf[i] == 0x0D || i == 0 || buf[i - 1] != 0x0D {
                // i == start: genuine empty line — but skip the \n half of a \r\n pair.
                lines.append("")
            }
            start = i + 1
        }
        if start > 0 { buf.removeFirst(start) }
        lock.unlock()
        for l in lines { handler(l) }
    }

    func flush() {
        lock.lock()
        let rest = buf
        buf.removeAll()
        lock.unlock()
        if !rest.isEmpty, let s = String(bytes: rest, encoding: .utf8) { handler(s) }
    }
}

/// Runs 7zz with streamed output. Callbacks arrive on background queues.
final class SevenZipProcess: @unchecked Sendable {
    private var process: Process?
    private let lock = NSLock()
    private let progressRe = try! NSRegularExpression(pattern: #"^\s*(\d{1,3})%"#)

    var isRunning: Bool { lock.withLock { process != nil } }

    func run(arguments: [String],
             onLine: @escaping @Sendable (String) -> Void,
             onProgress: @escaping @Sendable (Double) -> Void,
             completion: @escaping @Sendable (Int32) -> Void) throws {
        guard let exe = SevenZip.executableURL else { throw SevenZipError.binaryNotFound }
        let p = Process()
        p.executableURL = exe
        p.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        let re = progressRe
        let outPump = LinePump { line in
            onLine(line)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            if let m = re.firstMatch(in: line, range: range), m.numberOfRanges > 1,
               let r = Range(m.range(at: 1), in: line), let pct = Double(line[r]) {
                onProgress(min(pct / 100.0, 1.0))
            }
        }
        let errPump = LinePump(handler: onLine)

        lock.withLock { process = p }
        try p.run()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let fh = outPipe.fileHandleForReading
            while true {
                let d = fh.readData(ofLength: 8192)
                if d.isEmpty { break }
                outPump.feed(d)
            }
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            let fh = errPipe.fileHandleForReading
            while true {
                let d = fh.readData(ofLength: 8192)
                if d.isEmpty { break }
                errPump.feed(d)
            }
            group.leave()
        }
        DispatchQueue.global().async {
            p.waitUntilExit()
            group.wait()
            outPump.flush()
            errPump.flush()
            let status = p.terminationStatus
            self.lock.withLock { self.process = nil }
            completion(status)
        }
    }

    func cancel() {
        lock.withLock { process?.terminate() }
    }

    /// Async convenience that collects all output lines into a single string.
    func collect(arguments: [String]) async throws -> (Int32, String) {
        final class Box: @unchecked Sendable {
            private var t = ""
            private let l = NSLock()
            func add(_ s: String) { l.lock(); t += s + "\n"; l.unlock() }
            var text: String { l.lock(); defer { l.unlock() }; return t }
        }
        let box = Box()
        return try await withCheckedThrowingContinuation { cont in
            do {
                try run(arguments: arguments,
                        onLine: { box.add($0) },
                        onProgress: { _ in },
                        completion: { cont.resume(returning: ($0, box.text)) })
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
}
