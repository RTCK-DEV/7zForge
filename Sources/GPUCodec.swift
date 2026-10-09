import Foundation
import Metal
import CryptoKit

enum GPUError: Error, LocalizedError {
    case noDevice, noLibrary, noFunction, badMagic, tooLarge, badInput
    var errorDescription: String? {
        switch self {
        case .noDevice: "Metal デバイスが見つかりません"
        case .noLibrary: "metallib が見つかりません"
        case .noFunction: "シェーダ関数が見つかりません"
        case .badMagic: "Z7X3 ファイルではありません"
        case .tooLarge: "実験上限 512MB を超えています"
        case .badInput: "入力が不正または空です"
        }
    }
}

struct Z7XParams {
    var totalSize: UInt64 = 0
    var blockSize: UInt32 = 0
    var segSize: UInt32 = 0
    var numBlocks: UInt32 = 0
    var litCap: UInt32 = 0
    var codeCap: UInt32 = 0
    var offCap: UInt32 = 0
    var ransLitCap: UInt32 = 0
    var ransCodeCap: UInt32 = 0
    var ransOffCap: UInt32 = 0
    var probeDepth: UInt32 = 0
    var lazyDepth: UInt32 = 0
}

struct Z7XBlockInfo {
    var compOffset: UInt64 = 0
    var compSize: UInt32 = 0
    var origSize: UInt32 = 0
    var mode: UInt32 = 0
}

struct Z7XSegInfo {
    var litOff: UInt32 = 0
    var litLen: UInt32 = 0
    var codeOff: UInt32 = 0
    var codeLen: UInt32 = 0
    var offOff: UInt32 = 0
    var offLen: UInt32 = 0
    var litTok: UInt32 = 0
    var codeTok: UInt32 = 0
    var offTok: UInt32 = 0
}

struct Z7XCompressed: Sendable {
    var file = Data()
    var gpuMs = 0.0
}

struct Z7XStats: Sendable {
    var inputBytes = 0
    var outputBytes = 0
    var ratio: Double { outputBytes > 0 ? Double(inputBytes) / Double(outputBytes) : 0 }
    var gpuCompressMs = 0.0
    var wallCompressMs = 0.0
    var gpuDecompressMs = 0.0
    var wallDecompressMs = 0.0
    var blocks = 0
    var storedBlocks = 0
    var ransBlocks = 0
    var verified = false
    var compressMBps: Double { wallCompressMs > 0 ? Double(inputBytes) / 1e6 / (wallCompressMs / 1000) : 0 }
    var decompressMBps: Double { wallDecompressMs > 0 ? Double(inputBytes) / 1e6 / (wallDecompressMs / 1000) : 0 }
}

final class GPUCodec: @unchecked Sendable {
    static let blockSize = 1 << 20       // 1 MB blocks
    static let segSize = 16384           // 16 KB per GPU thread
    static let litCap = segSize          // lit channel cap (all-literal worst case)
    static let codeCap = segSize * 3 / 4 // opcode channel cap (2B rep tokens per 4B output)
    static let offCap = segSize             // offset channel cap (4B per len-4 far match)
    static let ransLitCap = litCap + litCap / 4 + 64
    static let ransCodeCap = codeCap + codeCap / 4 + 64
    static let ransOffCap = offCap + offCap / 4 + 64
    static let hashEntries = 1 << 21
    static let maxInput = 512 << 20

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let compPSO, histPSO, encPSO, rdecPSO: MTLComputePipelineState
    private let parsePSO, chasePSO, matPSO, seqPSO, dpPSO: MTLComputePipelineState

    init() throws {
        guard let d = MTLCreateSystemDefaultDevice() else { throw GPUError.noDevice }
        guard let q = d.makeCommandQueue() else { throw GPUError.noDevice }
        guard let lib = try? d.makeDefaultLibrary(bundle: .main) else { throw GPUError.noLibrary }
        func f(_ n: String) throws -> MTLComputePipelineState {
            guard let fn = lib.makeFunction(name: n) else { throw GPUError.noFunction }
            return try d.makeComputePipelineState(function: fn)
        }
        compPSO = try f("z7x_compress")
        histPSO = try f("z7x_hist")
        encPSO = try f("z7x_ransenc")
        rdecPSO = try f("z7x_ransdec")
        parsePSO = try f("z7x_parse")
        chasePSO = try f("z7x_chase")
        matPSO = try f("z7x_materialize")
        seqPSO = try f("z7x_decompress_seq")
        dpPSO = try f("z7x_dp")
        device = d
        queue = q
    }

    private func dispatch(_ pso: MTLComputePipelineState, count: Int,
                          configure: (MTLComputeCommandEncoder) -> Void) -> Double {
        let cmd = queue.makeCommandBuffer()!
        let enc = cmd.makeComputeCommandEncoder()!
        enc.setComputePipelineState(pso)
        configure(enc)
        let w = min(pso.maxTotalThreadsPerThreadgroup, 256)
        enc.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: w, height: 1, depth: 1))
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        return (cmd.gpuEndTime - cmd.gpuStartTime) * 1000
    }

    /// depth: hash-chain probe depth (4..24), lazy: lookahead distance (0..3)
    func compress(_ data: Data, depth: UInt32 = 24, lazy: UInt32 = 3, dumpChannels: Bool = false)
        throws -> (file: Data, gpuMs: Double, blocks: Int, stored: Int, rans: Int,
                   lit: Data?, code: Data?, off: Data?) {
        let total = data.count
        let numBlocks = (total + Self.blockSize - 1) / Self.blockSize
        let numSegs = (total + Self.segSize - 1) / Self.segSize
        var params = Z7XParams(totalSize: UInt64(total), blockSize: UInt32(Self.blockSize),
                               segSize: UInt32(Self.segSize), numBlocks: UInt32(numBlocks),
                               litCap: UInt32(Self.litCap), codeCap: UInt32(Self.codeCap),
                               offCap: UInt32(Self.offCap),
                               ransLitCap: UInt32(Self.ransLitCap), ransCodeCap: UInt32(Self.ransCodeCap),
                               ransOffCap: UInt32(Self.ransOffCap),
                               probeDepth: depth == 99 ? 24 : depth, lazyDepth: lazy)
        func buf(_ n: Int) -> MTLBuffer { device.makeBuffer(length: max(n, 4), options: .storageModeShared)! }

        let inBuf = data.withUnsafeBytes { p -> MTLBuffer in
            let ptr = UnsafeMutableRawPointer(mutating: p.baseAddress!)
            if let b = device.makeBuffer(bytesNoCopy: ptr, length: total, options: .storageModeShared, deallocator: nil) { return b }
            return device.makeBuffer(bytes: ptr, length: total, options: .storageModeShared)!
        }
        let litBuf = buf(Self.litCap * numSegs)
        let codeBuf = buf(Self.codeCap * numSegs)
        let offBuf = buf(Self.offCap * numSegs)
        let litLen = buf(4 * numSegs)
        let codeLen = buf(4 * numSegs)
        let offLen = buf(4 * numSegs)
        let heads = buf(96 * Self.hashEntries)
        let heads8 = buf(32 * Self.hashEntries)
        let hist = buf(768 * 4 * numBlocks)
        // GPU memset — CPU memset of ~230MB costs tens of ms
        let tFill = CFAbsoluteTimeGetCurrent()
        let fillCmd = queue.makeCommandBuffer()!
        let blit = fillCmd.makeBlitCommandEncoder()!
        blit.fill(buffer: heads, range: 0..<heads.length, value: 0)
        blit.fill(buffer: heads8, range: 0..<heads8.length, value: 0)
        blit.fill(buffer: hist, range: 0..<hist.length, value: 0)
        blit.endEncoding(); fillCmd.commit(); fillCmd.waitUntilCompleted()
        var gpuMs = (fillCmd.gpuEndTime - fillCmd.gpuStartTime) * 1000
        _ = tFill
        let tables = buf(768 * 2 * numBlocks)
        let ransLit = buf(Self.ransLitCap * numSegs)
        let ransCode = buf(Self.ransCodeCap * numSegs)
        let ransOff = buf(Self.ransOffCap * numSegs)
        let ransLitLen = buf(4 * numSegs)
        let ransCodeLen = buf(4 * numSegs)
        let ransOffLen = buf(4 * numSegs)

        if depth == 99 {   // optimal-parse mode: probe-all + DP + emit
            let lenArr = buf(Self.segSize * numSegs)
            let offArr = buf(4 * Self.segSize * numSegs)
            let costArr = buf(4 * Self.segSize * numSegs)
            gpuMs += dispatch(dpPSO, count: numSegs) { e in
                e.setBuffer(inBuf, offset: 0, index: 0); e.setBuffer(litBuf, offset: 0, index: 1)
                e.setBuffer(codeBuf, offset: 0, index: 2); e.setBuffer(offBuf, offset: 0, index: 3)
                e.setBuffer(litLen, offset: 0, index: 4); e.setBuffer(codeLen, offset: 0, index: 5)
                e.setBuffer(offLen, offset: 0, index: 6); e.setBuffer(heads, offset: 0, index: 7)
                e.setBuffer(heads8, offset: 0, index: 8); e.setBuffer(lenArr, offset: 0, index: 9)
                e.setBuffer(offArr, offset: 0, index: 10); e.setBuffer(costArr, offset: 0, index: 11)
                e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 12)
            }
        } else {
            gpuMs += dispatch(compPSO, count: numSegs) { e in
                e.setBuffer(inBuf, offset: 0, index: 0); e.setBuffer(litBuf, offset: 0, index: 1)
                e.setBuffer(codeBuf, offset: 0, index: 2); e.setBuffer(offBuf, offset: 0, index: 3)
                e.setBuffer(litLen, offset: 0, index: 4); e.setBuffer(codeLen, offset: 0, index: 5)
                e.setBuffer(offLen, offset: 0, index: 6); e.setBuffer(heads, offset: 0, index: 7)
                e.setBuffer(heads8, offset: 0, index: 8)
                e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 9)
            }
        }
        gpuMs += dispatch(histPSO, count: numSegs) { e in
            e.setBuffer(litBuf, offset: 0, index: 0); e.setBuffer(codeBuf, offset: 0, index: 1)
            e.setBuffer(offBuf, offset: 0, index: 2); e.setBuffer(litLen, offset: 0, index: 3)
            e.setBuffer(codeLen, offset: 0, index: 4); e.setBuffer(offLen, offset: 0, index: 5)
            e.setBuffer(hist, offset: 0, index: 6)
            e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 7)
        }
        gpuMs += dispatch(encPSO, count: numSegs) { e in
            e.setBuffer(litBuf, offset: 0, index: 0); e.setBuffer(codeBuf, offset: 0, index: 1)
            e.setBuffer(offBuf, offset: 0, index: 2); e.setBuffer(litLen, offset: 0, index: 3)
            e.setBuffer(codeLen, offset: 0, index: 4); e.setBuffer(offLen, offset: 0, index: 5)
            e.setBuffer(hist, offset: 0, index: 6); e.setBuffer(tables, offset: 0, index: 7)
            e.setBuffer(ransLit, offset: 0, index: 8); e.setBuffer(ransCode, offset: 0, index: 9)
            e.setBuffer(ransOff, offset: 0, index: 10); e.setBuffer(ransLitLen, offset: 0, index: 11)
            e.setBuffer(ransCodeLen, offset: 0, index: 12); e.setBuffer(ransOffLen, offset: 0, index: 13)
            e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 14)
        }

        let nl = litLen.contents().bindMemory(to: UInt32.self, capacity: numSegs)
        let nc = codeLen.contents().bindMemory(to: UInt32.self, capacity: numSegs)
        let no = offLen.contents().bindMemory(to: UInt32.self, capacity: numSegs)
        let rl = ransLitLen.contents().bindMemory(to: UInt32.self, capacity: numSegs)
        let rc = ransCodeLen.contents().bindMemory(to: UInt32.self, capacity: numSegs)
        let ro = ransOffLen.contents().bindMemory(to: UInt32.self, capacity: numSegs)
        let litBase = litBuf.contents(), codeBase = codeBuf.contents(), offBase = offBuf.contents()
        let rLitBase = ransLit.contents(), rCodeBase = ransCode.contents(), rOffBase = ransOff.contents()
        let tblBase = tables.contents()

        var payload = Data()
        payload.reserveCapacity(total)
        var dumpLit = dumpChannels ? Data() : nil
        var dumpCode = dumpChannels ? Data() : nil
        var dumpOff = dumpChannels ? Data() : nil
        var infos = [Z7XBlockInfo]()
        var stored = 0, ransBlocks = 0

        for b in 0..<numBlocks {
            var info = Z7XBlockInfo()
            let blkStart = b * Self.blockSize
            let seg0 = blkStart / Self.segSize
            let segCount = (min(Self.blockSize, total - blkStart) + Self.segSize - 1) / Self.segSize
            info.origSize = UInt32(min(Self.blockSize, total - blkStart))
            info.compOffset = UInt64(payload.count)

            var litTok = 0, codeTok = 0, offTok = 0, litRans = 0, codeRans = 0, offRans = 0
            for s in seg0..<seg0 + segCount {
                litTok += Int(nl[s]); codeTok += Int(nc[s]); offTok += Int(no[s])
                litRans += Int(rl[s]); codeRans += Int(rc[s]); offRans += Int(ro[s])
            }
            if dumpChannels {
                for s in seg0..<seg0 + segCount {
                    dumpLit!.append(Data(bytes: litBase + s * Self.litCap, count: Int(nl[s])))
                    dumpCode!.append(Data(bytes: codeBase + s * Self.codeCap, count: Int(nc[s])))
                    dumpOff!.append(Data(bytes: offBase + s * Self.offCap, count: Int(no[s])))
                }
            }
            var ransFit = true
            for s in seg0..<seg0 + segCount {
                if Int(rl[s]) > Self.ransLitCap || Int(rc[s]) > Self.ransCodeCap ||
                   Int(ro[s]) > Self.ransOffCap { ransFit = false; break }
            }
            let m1 = 12 + litTok + codeTok + offTok
            let m2 = ransFit ? 1536 + 4 + 24 * segCount + litRans + codeRans + offRans : Int.max
            if Int(info.origSize) <= m1 && Int(info.origSize) <= m2 {
                info.mode = 0
                info.compSize = info.origSize
                payload.append(data[data.startIndex + blkStart ..< data.startIndex + blkStart + Int(info.origSize)])
                stored += 1
            } else if m1 <= m2 {
                info.mode = 1
                info.compSize = UInt32(m1)
                payload.appendLE(UInt32(litTok))
                payload.appendLE(UInt32(codeTok))
                payload.appendLE(UInt32(offTok))
                for s in seg0..<seg0 + segCount {
                    payload.append(Data(bytes: litBase + s * Self.litCap, count: Int(nl[s])))
                }
                for s in seg0..<seg0 + segCount {
                    payload.append(Data(bytes: codeBase + s * Self.codeCap, count: Int(nc[s])))
                }
                for s in seg0..<seg0 + segCount {
                    payload.append(Data(bytes: offBase + s * Self.offCap, count: Int(no[s])))
                }
            } else {
                info.mode = 2
                info.compSize = UInt32(m2)
                payload.append(Data(bytes: tblBase + b * 1536, count: 1536))
                payload.appendLE(UInt32(segCount))
                for s in seg0..<seg0 + segCount { payload.appendLE(nl[s]) }
                for s in seg0..<seg0 + segCount { payload.appendLE(nc[s]) }
                for s in seg0..<seg0 + segCount { payload.appendLE(no[s]) }
                for s in seg0..<seg0 + segCount { payload.appendLE(rl[s]) }
                for s in seg0..<seg0 + segCount { payload.appendLE(rc[s]) }
                for s in seg0..<seg0 + segCount { payload.appendLE(ro[s]) }
                for s in seg0..<seg0 + segCount {
                    payload.append(Data(bytes: rLitBase + s * Self.ransLitCap, count: Int(rl[s])))
                }
                for s in seg0..<seg0 + segCount {
                    payload.append(Data(bytes: rCodeBase + s * Self.ransCodeCap, count: Int(rc[s])))
                }
                for s in seg0..<seg0 + segCount {
                    payload.append(Data(bytes: rOffBase + s * Self.ransOffCap, count: Int(ro[s])))
                }
                ransBlocks += 1
            }
            infos.append(info)
        }

        var file = Data(capacity: 28 + numBlocks * 20 + payload.count)
        file.append("Z7X3".data(using: .ascii)!)
        file.appendLE(UInt32(3))
        file.appendLE(UInt32(Self.blockSize))
        file.appendLE(UInt32(Self.segSize))
        file.appendLE(UInt32(numBlocks))
        file.appendLE(UInt64(total))
        for i in infos {
            file.appendLE(i.compOffset)
            file.appendLE(i.compSize)
            file.appendLE(i.origSize)
            file.appendLE(i.mode)
        }
        file.append(payload)
        return (file, gpuMs, numBlocks, stored, ransBlocks, dumpLit, dumpCode, dumpOff)
    }

    func decompress(_ file: Data) throws -> (Data, Double) {
        guard file.count > 28, file[0..<4] == "Z7X3".data(using: .ascii)! else { throw GPUError.badMagic }
        var off = 4
        _ = file.readLE(UInt32.self, &off)
        let blockSize = Int(file.readLE(UInt32.self, &off))
        let segSize = Int(file.readLE(UInt32.self, &off))
        let numBlocks = Int(file.readLE(UInt32.self, &off))
        let origSize = Int(file.readLE(UInt64.self, &off))
        guard blockSize > 0, segSize > 0, blockSize % segSize == 0,
              origSize > 0, origSize <= Self.maxInput,
              numBlocks == (origSize + blockSize - 1) / blockSize else { throw GPUError.badMagic }
        var infos = [Z7XBlockInfo]()
        for _ in 0..<numBlocks {
            var bi = Z7XBlockInfo()
            bi.compOffset = file.readLE(UInt64.self, &off)
            bi.compSize = file.readLE(UInt32.self, &off)
            bi.origSize = file.readLE(UInt32.self, &off)
            bi.mode = file.readLE(UInt32.self, &off)
            infos.append(bi)
        }
        let payloadStart = off
        let payload = file.subdata(in: payloadStart..<file.count)
        let numSegs = (origSize + segSize - 1) / segSize

        var segs = [Z7XSegInfo](repeating: Z7XSegInfo(), count: numSegs)
        var litOffs = [UInt32](repeating: 0, count: numSegs)
        var codeOffs = [UInt32](repeating: 0, count: numSegs)
        var offOffs = [UInt32](repeating: 0, count: numSegs)
        var modeFlag = [UInt32](repeating: 0, count: numBlocks)
        var tables = [UInt16](repeating: 0, count: numBlocks * 768)
        var litCursor = 0, codeCursor = 0, offCursor = 0

        for b in 0..<numBlocks {
            let info = infos[b]
            modeFlag[b] = info.mode
            guard info.mode <= 2, Int(info.compOffset) + Int(info.compSize) <= payload.count else { throw GPUError.badMagic }
            guard info.mode == 2 else { continue }
            var p = Int(info.compOffset)
            guard p + 1536 <= payload.count else { throw GPUError.badMagic }
            payload[p ..< p + 1536].withUnsafeBytes { ptr in
                tables.replaceSubrange(b * 768 ..< b * 768 + 768,
                                       with: ptr.bindMemory(to: UInt16.self))
            }
            p += 1536
            guard p + 4 <= payload.count else { throw GPUError.badMagic }
            let segCount = Int(payload.readLE(UInt32.self, &p))
            guard p + 24 * segCount <= payload.count else { throw GPUError.badMagic }
            let seg0 = b * blockSize / segSize
            var litTok = [UInt32](repeating: 0, count: segCount)
            var codeTok = [UInt32](repeating: 0, count: segCount)
            var offTok = [UInt32](repeating: 0, count: segCount)
            var litRans = [UInt32](repeating: 0, count: segCount)
            var codeRans = [UInt32](repeating: 0, count: segCount)
            var offRans = [UInt32](repeating: 0, count: segCount)
            for i in 0..<segCount { litTok[i] = payload.readLE(UInt32.self, &p) }
            for i in 0..<segCount { codeTok[i] = payload.readLE(UInt32.self, &p) }
            for i in 0..<segCount { offTok[i] = payload.readLE(UInt32.self, &p) }
            for i in 0..<segCount { litRans[i] = payload.readLE(UInt32.self, &p) }
            for i in 0..<segCount { codeRans[i] = payload.readLE(UInt32.self, &p) }
            for i in 0..<segCount { offRans[i] = payload.readLE(UInt32.self, &p) }
            var litBase = p
            for i in 0..<segCount { litBase += Int(litRans[i]) }
            var codeBase = litBase
            for i in 0..<segCount { codeBase += Int(codeRans[i]) }
            var offBase = codeBase
            for i in 0..<segCount { offBase += Int(offRans[i]) }
            guard offBase <= payload.count else { throw GPUError.badMagic }
            var litCur = p, codeCur = litBase, offCur = codeBase
            for i in 0..<segCount {
                let g = seg0 + i
                segs[g] = Z7XSegInfo(litOff: UInt32(litCur), litLen: litRans[i],
                                     codeOff: UInt32(codeCur), codeLen: codeRans[i],
                                     offOff: UInt32(offCur), offLen: offRans[i],
                                     litTok: litTok[i], codeTok: codeTok[i], offTok: offTok[i])
                litOffs[g] = UInt32(litCursor); codeOffs[g] = UInt32(codeCursor); offOffs[g] = UInt32(offCursor)
                litCursor += Int(litTok[i]); codeCursor += Int(codeTok[i]); offCursor += Int(offTok[i])
                litCur += Int(litRans[i]); codeCur += Int(codeRans[i]); offCur += Int(offRans[i])
            }
        }

        if modeFlag.allSatisfy({ $0 == 0 }) {
            var out = Data(count: origSize)
            out.withUnsafeMutableBytes { dst in
                var o = 0
                for b in 0..<numBlocks {
                    let info = infos[b]
                    let s = Int(info.compOffset), n = Int(info.origSize)
                    payload.withUnsafeBytes { src in
                        memcpy(dst.baseAddress! + o, src.baseAddress! + s, n)
                    }
                    o += n
                }
            }
            return (out, 0)
        }

        func buf(_ n: Int) -> MTLBuffer { device.makeBuffer(length: max(n, 4), options: .storageModeShared)! }
        var params = Z7XParams(totalSize: UInt64(origSize), blockSize: UInt32(blockSize),
                               segSize: UInt32(segSize), numBlocks: UInt32(numBlocks),
                               litCap: UInt32(Self.litCap), codeCap: UInt32(Self.codeCap),
                               offCap: UInt32(Self.offCap),
                               ransLitCap: UInt32(Self.ransLitCap), ransCodeCap: UInt32(Self.ransCodeCap),
                               ransOffCap: UInt32(Self.ransOffCap))
        let payBuf = payload.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: payload.count, options: .storageModeShared)! }
        let outBuf = buf(numBlocks * blockSize)
        let infoBuf = infos.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 24, options: .storageModeShared)! }
        let segsBuf = segs.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 36, options: .storageModeShared)! }
        let tblBuf = tables.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 2, options: .storageModeShared)! }
        let loBuf = litOffs.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)! }
        let coBuf = codeOffs.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)! }
        let ooBuf = offOffs.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)! }
        let mfBuf = modeFlag.withUnsafeBufferPointer { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count * 4, options: .storageModeShared)! }
        let litScratch = buf(litCursor)
        let codeScratch = buf(codeCursor)
        let offScratch = buf(offCursor)

        let srcPos = buf(origSize * 4)
        let unresolved = buf(4)

        var gpuMs = 0.0
        gpuMs += dispatch(rdecPSO, count: numSegs) { e in
            e.setBuffer(payBuf, offset: 0, index: 0); e.setBuffer(segsBuf, offset: 0, index: 1)
            e.setBuffer(tblBuf, offset: 0, index: 2); e.setBuffer(loBuf, offset: 0, index: 3)
            e.setBuffer(coBuf, offset: 0, index: 4); e.setBuffer(ooBuf, offset: 0, index: 5)
            e.setBuffer(mfBuf, offset: 0, index: 6); e.setBuffer(litScratch, offset: 0, index: 7)
            e.setBuffer(codeScratch, offset: 0, index: 8); e.setBuffer(offScratch, offset: 0, index: 9)
            e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 10)
        }
        gpuMs += dispatch(parsePSO, count: numSegs) { e in
            e.setBuffer(codeScratch, offset: 0, index: 0); e.setBuffer(offScratch, offset: 0, index: 1)
            e.setBuffer(srcPos, offset: 0, index: 2); e.setBuffer(loBuf, offset: 0, index: 3)
            e.setBuffer(coBuf, offset: 0, index: 4); e.setBuffer(ooBuf, offset: 0, index: 5)
            e.setBuffer(mfBuf, offset: 0, index: 6)
            e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 7)
        }
        for _ in 0..<24 {
            memset(unresolved.contents(), 0, 4)
            gpuMs += dispatch(chasePSO, count: origSize) { e in
                e.setBuffer(srcPos, offset: 0, index: 0); e.setBuffer(unresolved, offset: 0, index: 1)
                e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 2)
            }
            if unresolved.contents().load(as: UInt32.self) == 0 { break }
        }
        gpuMs += dispatch(matPSO, count: origSize) { e in
            e.setBuffer(outBuf, offset: 0, index: 0); e.setBuffer(litScratch, offset: 0, index: 1)
            e.setBuffer(srcPos, offset: 0, index: 2); e.setBuffer(mfBuf, offset: 0, index: 3)
            e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 4)
        }
        gpuMs += dispatch(seqPSO, count: numBlocks) { e in
            e.setBuffer(payBuf, offset: 0, index: 0); e.setBuffer(outBuf, offset: 0, index: 1)
            e.setBuffer(infoBuf, offset: 0, index: 2); e.setBuffer(mfBuf, offset: 0, index: 3)
            e.setBytes(&params, length: MemoryLayout<Z7XParams>.size, index: 4)
        }
        let out = Data(bytesNoCopy: outBuf.contents(), count: origSize, deallocator: .custom { [outBuf] _, _ in _ = outBuf })
        return (out, gpuMs)
    }

    func roundtrip(_ data: Data, depth: UInt32 = 24, lazy: UInt32 = 3) throws -> Z7XStats {
        var st = Z7XStats(inputBytes: data.count)
        let t0 = CFAbsoluteTimeGetCurrent()
        let r = try compress(data, depth: depth, lazy: lazy)
        st.gpuCompressMs = r.gpuMs
        st.wallCompressMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        st.outputBytes = r.file.count
        st.blocks = r.blocks
        st.storedBlocks = r.stored
        st.ransBlocks = r.rans

        let t1 = CFAbsoluteTimeGetCurrent()
        let (back, dg) = try decompress(r.file)
        st.gpuDecompressMs = dg
        st.wallDecompressMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        st.verified = SHA256.hash(data: back) == SHA256.hash(data: data) && back.count == data.count
        return st
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ v: T) {
        var x = v.littleEndian
        Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) }
    }
    func readLE<T: FixedWidthInteger>(_ t: T.Type, _ off: inout Int) -> T {
        let v = self[off..<off + MemoryLayout<T>.size].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        off += MemoryLayout<T>.size
        return T(littleEndian: v)
    }
}
