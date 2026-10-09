import Foundation

/// Minimal MCP (Model Context Protocol) stdio server.
/// JSON-RPC 2.0, one message per line on stdin/stdout. Nothing else may write to stdout.
/// Exposes the bundled 7zz binary and the GPU Z7X codec as tools.
enum MCPServer {

    // MARK: - tool definitions

    nonisolated(unsafe) static let tools: [[String: Any]] = [
        [
            "name": "sevenz_compress",
            "description": "Compress files/dirs with bundled 7-Zip (7z/zip, LZMA2/LZMA/PPMd/BZip2/Deflate, AES encryption).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "inputs":  ["type": "array", "items": ["type": "string"], "description": "file/dir paths"],
                    "archive": ["type": "string", "description": "output archive path"],
                    "format":  ["type": "string", "enum": ["7z", "zip"], "default": "7z"],
                    "codec":   ["type": "string", "enum": ["LZMA2", "LZMA", "PPMd", "BZip2", "Deflate", "Deflate64", "Copy"], "default": "LZMA2"],
                    "level":   ["type": "integer", "minimum": 0, "maximum": 9, "default": 5],
                    "threads": ["type": "integer", "default": 0, "description": "0=all cores"],
                    "dictMB":  ["type": "integer", "default": 0],
                    "solid":   ["type": "boolean", "default": true],
                    "password": ["type": "string"],
                    "headerEncrypt": ["type": "boolean", "default": true],
                ],
                "required": ["inputs", "archive"],
            ],
        ],
        [
            "name": "sevenz_extract",
            "description": "Extract a 7z/zip/tar/xz/zst/… archive with 7-Zip.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "archive":   ["type": "string"],
                    "dest":      ["type": "string", "description": "output dir (default: beside archive)"],
                    "entries":   ["type": "array", "items": ["type": "string"], "description": "selected paths inside archive (default: all)"],
                    "password":  ["type": "string"],
                    "overwrite": ["type": "boolean", "default": true],
                ],
                "required": ["archive"],
            ],
        ],
        [
            "name": "sevenz_list",
            "description": "List archive entries (path/size/packedSize/modified/isDirectory).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "archive":  ["type": "string"],
                    "password": ["type": "string"],
                ],
                "required": ["archive"],
            ],
        ],
        [
            "name": "z7x_compress",
            "description": "Compress a file with the experimental Metal GPU codec (.z7x, single stream). profile: 0=fast 1=balanced 2=max.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "input":   ["type": "string"],
                    "output":  ["type": "string"],
                    "profile": ["type": "integer", "minimum": 0, "maximum": 3, "default": 1,
                                "description": "0=爆速 d4 1=バランス d8/lazy1 2=最大 d24/lazy3 3=DP実験"],
                ],
                "required": ["input", "output"],
            ],
        ],
        [
            "name": "z7x_decompress",
            "description": "Decompress a .z7x file with the Metal GPU codec (~1.3GB/s).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "input":  ["type": "string"],
                    "output": ["type": "string"],
                ],
                "required": ["input", "output"],
            ],
        ],
        [
            "name": "sevenz_bench",
            "description": "Run `7zz b` synthetic benchmark at a given thread count; returns compress/decompress MIPS.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "threads": ["type": "integer", "default": 0, "description": "0=all cores"],
                ],
            ],
        ],
    ]

    // MARK: - JSON-RPC loop

    static func run() -> Never {
        let stdout = FileHandle.standardOutput
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let req = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = req["method"] as? String else { continue }
            let id = req["id"]  // may be NSNull/absent -> notification
            switch method {
            case "initialize":
                respond(stdout, id: id, result: [
                    "protocolVersion": "2024-11-05",
                    "capabilities": ["tools": ["listChanged": false]],
                    "serverInfo": ["name": "z7forge", "version": "1.0.0"],
                ])
            case "ping":
                respond(stdout, id: id, result: [:])
            case "tools/list":
                respond(stdout, id: id, result: ["tools": tools])
            case "tools/call":
                guard let params = req["params"] as? [String: Any],
                      let name = params["name"] as? String else {
                    respondError(stdout, id: id, code: -32602, msg: "missing params.name"); continue
                }
                let args = (params["arguments"] as? [String: Any]) ?? [:]
                callTool(stdout, id: id, name: name, args: args)
            default:
                if method.hasPrefix("notifications/") || id == nil { continue }
                respondError(stdout, id: id, code: -32601, msg: "method not found: \(method)")
            }
        }
        exit(0)
    }

    static func respond(_ out: FileHandle, id: Any?, result: [String: Any]) {
        guard let id else { return }
        write(out, ["jsonrpc": "2.0", "id": id, "result": result])
    }

    static func respondError(_ out: FileHandle, id: Any?, code: Int, msg: String) {
        guard let id else { return }
        write(out, ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": msg]])
    }

    static func toolResult(_ out: FileHandle, id: Any?, text: String, isError: Bool = false) {
        respond(out, id: id, result: [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ])
    }

    static func write(_ out: FileHandle, _ obj: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]),
              var s = String(data: d, encoding: .utf8) else { return }
        s += "\n"
        out.write(s.data(using: .utf8)!)
    }

    // MARK: - tools

    static func callTool(_ out: FileHandle, id: Any?, name: String, args: [String: Any]) {
        do {
            switch name {
            case "sevenz_compress":    try tCompress(out, id: id, args: args)
            case "sevenz_extract":     try tExtract(out, id: id, args: args)
            case "sevenz_list":        try tList(out, id: id, args: args)
            case "z7x_compress":       try tZ7XCompress(out, id: id, args: args)
            case "z7x_decompress":     try tZ7XDecompress(out, id: id, args: args)
            case "sevenz_bench":       try tBench(out, id: id, args: args)
            default:
                toolResult(out, id: id, text: "unknown tool: \(name)", isError: true)
            }
        } catch {
            toolResult(out, id: id, text: "error: \(error.localizedDescription)", isError: true)
        }
    }

    /// Synchronous 7zz execution with both pipes drained (stderr concurrently to avoid deadlock).
    static func exec7zz(_ args: [String]) throws -> (Int32, String) {
        guard let exe = SevenZip.executableURL else { throw SevenZipError.binaryNotFound }
        let p = Process()
        p.executableURL = exe
        p.arguments = args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        final class Box: @unchecked Sendable { var d = Data() }
        let box = Box()
        let g = DispatchGroup()
        g.enter()
        Thread.detachNewThread {
            box.d = e.fileHandleForReading.readDataToEndOfFile()
            g.leave()
        }
        try p.run()
        let od = o.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        g.wait()
        return (p.terminationStatus,
                String(decoding: od, as: UTF8.self) + String(decoding: box.d, as: UTF8.self))
    }

    static func str(_ args: [String: Any], _ k: String) -> String? { args[k] as? String }
    static func int(_ args: [String: Any], _ k: String, _ d: Int) -> Int {
        (args[k] as? Int) ?? Int((args[k] as? String) ?? "") ?? d
    }

    static func tCompress(_ out: FileHandle, id: Any?, args: [String: Any]) throws {
        guard let inputs = args["inputs"] as? [String], !inputs.isEmpty,
              let arch = str(args, "archive") else {
            toolResult(out, id: id, text: "inputs[] and archive are required", isError: true); return
        }
        var o = CompressOptions()
        o.format = SZFormat(rawValue: str(args, "format") ?? "7z") ?? .sevenZ
        o.codec = SZCodec(rawValue: str(args, "codec") ?? "LZMA2") ?? .lzma2
        o.level = int(args, "level", 5)
        o.threads = int(args, "threads", 0)
        o.dictMB = int(args, "dictMB", 0)
        o.solid = (args["solid"] as? Bool) ?? true
        o.password = str(args, "password") ?? ""
        o.headerEncrypt = (args["headerEncrypt"] as? Bool) ?? true
        let a = SevenZip.compressArgs(o, archive: URL(fileURLWithPath: arch),
                                      inputs: inputs.map { URL(fileURLWithPath: $0) })
        let (status, text) = try exec7zz(a)
        let size = (try? FileManager.default.attributesOfItem(atPath: arch)[.size] as? Int) ?? 0
        toolResult(out, id: id, text:
            "exit=\(status) archive=\(arch) size=\(size)B\n" + text.suffix(4000),
            isError: status != 0)
    }

    static func tExtract(_ out: FileHandle, id: Any?, args: [String: Any]) throws {
        guard let arch = str(args, "archive") else {
            toolResult(out, id: id, text: "archive required", isError: true); return
        }
        let au = URL(fileURLWithPath: arch)
        let dest = str(args, "dest").map { URL(fileURLWithPath: $0) }
            ?? au.deletingLastPathComponent().appendingPathComponent(au.deletingPathExtension().lastPathComponent)
        var ents: [ArchiveEntry] = []
        if let names = args["entries"] as? [String] {
            ents = names.map { ArchiveEntry(path: $0) }
        }
        let a = SevenZip.extractArgs(archive: au, dest: dest, entries: ents,
                                     password: str(args, "password") ?? "",
                                     overwrite: (args["overwrite"] as? Bool) ?? true)
        let (status, text) = try exec7zz(a)
        toolResult(out, id: id, text: "exit=\(status) dest=\(dest.path)\n" + text.suffix(4000),
                   isError: status != 0)
    }

    static func tList(_ out: FileHandle, id: Any?, args: [String: Any]) throws {
        guard let arch = str(args, "archive") else {
            toolResult(out, id: id, text: "archive required", isError: true); return
        }
        let a = SevenZip.listArgs(archive: URL(fileURLWithPath: arch),
                                  password: str(args, "password") ?? "")
        let (status, text) = try exec7zz(a)
        guard status == 0 else {
            toolResult(out, id: id, text: "list failed (exit \(status))\n" + text.suffix(2000), isError: true)
            return
        }
        let entries = SevenZip.parseListing(text).map { e in
            ["path": e.path, "size": e.size, "packedSize": e.packedSize,
             "modified": e.modified, "isDirectory": e.isDirectory] as [String: Any]
        }
        respond(out, id: id, result: [
            "content": [["type": "text",
                         "text": String(data: (try? JSONSerialization.data(
                            withJSONObject: entries, options: .prettyPrinted)) ?? Data(), encoding: .utf8) ?? "[]"]],
        ])
    }

    static func tZ7XCompress(_ out: FileHandle, id: Any?, args: [String: Any]) throws {
        guard let inp = str(args, "input"), let outp = str(args, "output") else {
            toolResult(out, id: id, text: "input and output required", isError: true); return
        }
        let profile = int(args, "profile", 1)
        let (d, l): (UInt32, UInt32) = [(4, 0), (8, 1), (24, 3), (99, 0)][min(max(profile, 0), 3)]
        let data = try Data(contentsOf: URL(fileURLWithPath: inp), options: .mappedIfSafe)
        let codec = try GPUCodec()
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try codec.compress(data, depth: d, lazy: l)
        let wall = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        try r.file.write(to: URL(fileURLWithPath: outp))
        toolResult(out, id: id, text: String(format:
            "ok %dB -> %dB (%.2fx) wall=%.0fms kernel=%.0fms blocks=%d stored=%d",
            data.count, r.file.count, Double(data.count) / max(1.0, Double(r.file.count)),
            wall, r.gpuMs, r.blocks, r.stored))
    }

    static func tZ7XDecompress(_ out: FileHandle, id: Any?, args: [String: Any]) throws {
        guard let inp = str(args, "input"), let outp = str(args, "output") else {
            toolResult(out, id: id, text: "input and output required", isError: true); return
        }
        let file = try Data(contentsOf: URL(fileURLWithPath: inp))
        let codec = try GPUCodec()
        let (back, ms) = try codec.decompress(file)
        try back.write(to: URL(fileURLWithPath: outp))
        toolResult(out, id: id, text: String(format: "ok %dB in %.0fms", back.count, ms))
    }

    static func tBench(_ out: FileHandle, id: Any?, args: [String: Any]) throws {
        let threads = int(args, "threads", 0)
        var a = ["b", "-mmt=\(threads > 0 ? "\(threads)" : "on")"]
        a.append("-bsp0")
        let (status, text) = try exec7zz(a)
        if let (c, d) = SevenZip.parseBenchTotal(text) {
            toolResult(out, id: id, text: String(format:
                "threads=%@ compress=%.0f MIPS decompress=%.0f MIPS",
                threads > 0 ? "\(threads)" : "all", c, d))
        } else {
            toolResult(out, id: id, text: "bench failed (exit \(status))\n" + text.suffix(2000), isError: true)
        }
    }
}
