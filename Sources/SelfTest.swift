import Foundation
import CryptoKit

/// Headless verification: `SevenZ --selftest <file>` exercises the bundled 7zz
/// roundtrip, -slt listing, and the Metal GPU codec roundtrip.
enum SelfTest {
    final class OutBox: @unchecked Sendable {
        private var text = ""
        private var status: Int32 = -1
        private let l = NSLock()
        func add(_ s: String) { l.lock(); text += s + "\n"; l.unlock() }
        func set(_ s: Int32) { l.lock(); status = s; l.unlock() }
        var get: (Int32, String) { l.lock(); defer { l.unlock() }; return (status, text) }
    }

    static func run() -> Never {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--dump-tokens"), args.count > i + 2 {
            dumpTokens(in: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--z7x-write"), args.count > i + 2 {
            z7xWrite(in: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--z7x-decode"), args.count > i + 2 {
            z7xDecode(in: URL(fileURLWithPath: args[i + 1]), out: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        }
        var depth: UInt32 = 24, lazy: UInt32 = 3
        if let i = args.firstIndex(of: "--depth"), args.count > i + 1 { depth = UInt32(args[i + 1]) ?? 24 }
        if let i = args.firstIndex(of: "--lazy"), args.count > i + 1 { lazy = UInt32(args[i + 1]) ?? 3 }
        let path = CommandLine.arguments.last ?? ""
        let url = URL(fileURLWithPath: path)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            FileHandle.standardError.write("selftest: cannot read \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        print("== selftest on \(url.lastPathComponent) (\(data.count) bytes)")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("z7_selftest_\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let arc = tmp.appendingPathComponent("t.7z")
        let xdir = tmp.appendingPathComponent("x")

        let proc = SevenZipProcess()
        let sem = DispatchSemaphore(value: 0)
        func runSync(_ args: [String]) -> (Int32, String) {
            let box = OutBox()
            do {
                try proc.run(arguments: args,
                             onLine: { box.add($0) },
                             onProgress: { _ in },
                             completion: { s in box.set(s); sem.signal() })
            } catch { return (-1, "\(error)") }
            sem.wait()
            return box.get
        }

        var o = CompressOptions()
        o.codec = .lzma2; o.level = 3
        let (s1, _) = runSync(SevenZip.compressArgs(o, archive: arc, inputs: [url]))
        let arcSize = (try? FileManager.default.attributesOfItem(atPath: arc.path)[.size] as? Int) ?? 0
        print("7zz a      -> code \(s1), archive \(arcSize)B")

        let (s2, listText) = runSync(SevenZip.listArgs(archive: arc, password: ""))
        let entries = SevenZip.parseListing(listText)
        print("7zz l -slt -> code \(s2), entries=\(entries.count)")
        if let e = entries.first { print("   first: \(e.path) size=\(e.size)") }

        let (s3, _) = runSync(SevenZip.extractArgs(archive: arc, dest: xdir,
                                                 entries: [], password: "", overwrite: true))
        var ok7z = false
        if let rel = entries.first?.path,
           let back = try? Data(contentsOf: xdir.appendingPathComponent(rel)) {
            ok7z = SHA256.hash(data: back) == SHA256.hash(data: data)
        }
        print("7zz x      -> code \(s3), sha256 match=\(ok7z)")

        do {
            let codec = try GPUCodec()
            let t0 = CFAbsoluteTimeGetCurrent()
            let r = try codec.compress(data, depth: depth, lazy: lazy)
            let wallC = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            let t1 = CFAbsoluteTimeGetCurrent()
            let (back, dg) = try codec.decompress(r.file)
            let wallD = (CFAbsoluteTimeGetCurrent() - t1) * 1000
            let ok = SHA256.hash(data: back) == SHA256.hash(data: data) && back.count == data.count
            print(String(format: "GPU z7x    -> comp %.1fms (kernel %.1fms) decomp %.1fms | %d -> %d bytes (%.2fx) | blocks %d stored %d | verify %@",
                         wallC, r.gpuMs, wallD, data.count, r.file.count,
                         Double(data.count) / Double(r.file.count),
                         r.blocks, r.stored, ok ? "OK" : "FAIL"))
        } catch {
            print("GPU z7x    -> ERROR \(error.localizedDescription)")
        }

        print("== done")
        exit(ok7z ? 0 : 1)
    }

    /// `--z7x-write <in> <out>`: writes the .z7x file and its decompression for debugging.
    static func z7xWrite(in url: URL, out: URL) {
        guard let data = try? Data(contentsOf: url) else { exit(2) }
        do {
            let codec = try GPUCodec()
            let r = try codec.compress(data)
            try r.file.write(to: out)
            let (back, _) = try codec.decompress(r.file)
            try back.write(to: out.appendingPathExtension("dec"))
            print("wrote \(r.file.count) -> \(out.path) (+ .dec \(back.count))")
        } catch {
            print("z7x-write failed: \(error)")
            exit(1)
        }
    }

    /// `--z7x-decode <in.z7x> <out>`: decodes a .z7x file (robustness testing).
    static func z7xDecode(in url: URL, out: URL) {
        guard let file = try? Data(contentsOf: url) else { exit(2) }
        do {
            let codec = try GPUCodec()
            let (back, _) = try codec.decompress(file)
            try back.write(to: out)
            print("decoded \(back.count) -> \(out.path)")
        } catch {
            print("z7x-decode rejected: \(error)")
            exit(1)
        }
    }

    /// `--dump-tokens <in> <out>`: writes lit/code/off channel dumps for entropy analysis.
    static func dumpTokens(in url: URL, out: URL) {
        guard let data = try? Data(contentsOf: url) else { exit(2) }
        do {
            let codec = try GPUCodec()
            let r = try codec.compress(data, dumpChannels: true)
            try r.lit!.write(to: out.appendingPathExtension("lit"))
            try r.code!.write(to: out.appendingPathExtension("code"))
            try r.off!.write(to: out.appendingPathExtension("off"))
            print("dumped lit=\(r.lit!.count) code=\(r.code!.count) off=\(r.off!.count) -> \(out.path).{lit,code,off}")
        } catch {
            print("dump failed: \(error)")
            exit(1)
        }
    }
}
