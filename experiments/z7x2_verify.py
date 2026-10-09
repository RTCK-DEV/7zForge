#!/usr/bin/env python3
"""Z7X3 ファイルを Python で完全デコード — Metal カーネル出力の正当性を検証する。"""
import struct, sys, hashlib

M = 4096; L = 1 << 24

def rans_dec(stream, n, cum):
    rp = len(stream) - 4
    x = int.from_bytes(stream[rp:rp+4], "little")
    out = bytearray()
    for _ in range(n):
        slot = x & 0xFFF
        lo, hi = 0, 255
        while lo < hi:
            mid = (lo + hi + 1)//2
            if cum[mid] <= slot: lo = mid
            else: hi = mid - 1
        f = cum[lo+1]-cum[lo]
        out.append(lo)
        x = f*(x >> 12) + slot - cum[lo]
        while x < L and rp > 0:
            rp -= 1; x = (x << 8) | stream[rp]
    return bytes(out)

def parse_block(lit, code, offS, wp, end, out):
    """Shared token parser (mode1 + mode2). Returns final out position."""
    rp = 0; op = 0; lp = 0
    rep1 = rep2 = rep3 = 0
    while wp < end:
        c = code[rp]; rp += 1
        if c < 128:
            n = c + 1
            out += lit[lp:lp+n]; lp += n; wp += n
        elif c >= 253:
            l = code[rp] + 4; rp += 1
            t1, t2 = rep1, rep2
            if c == 255:   o = rep1
            elif c == 254: o = rep2; rep2 = t1; rep1 = o
            else:          o = rep3; rep3 = t2; rep2 = t1; rep1 = o
            s = wp - o
            for k in range(l):
                out.append(out[s+k]); wp += 1
        elif c == 252:
            l = code[rp] + 4; rp += 1
            o = offS[op] | (offS[op+1]<<8) | (offS[op+2]<<16) | (offS[op+3]<<24); op += 4
            rep3 = rep2; rep2 = rep1; rep1 = o
            s = wp - o
            for k in range(l):
                out.append(out[s+k]); wp += 1
        else:
            l = c - 128 + 4
            o = offS[op] | (offS[op+1]<<8) | (offS[op+2]<<16); op += 3
            rep3 = rep2; rep2 = rep1; rep1 = o
            s = wp - o
            for k in range(l):
                out.append(out[s+k]); wp += 1
    return wp

def main(path, orig_path):
    file = open(path, "rb").read()
    assert file[:4] == b"Z7X3"
    off = 8
    blockSize, segSize, numBlocks = struct.unpack_from("<III", file, off); off += 12
    total, = struct.unpack_from("<Q", file, off); off += 8
    infos = []
    for _ in range(numBlocks):
        co, cs, os_, md = struct.unpack_from("<QIII", file, off); off += 20
        infos.append((co, cs, os_, md))
    payload = file[off:]
    out = bytearray()
    segs = {}
    for b, (co, cs, os_, md) in enumerate(infos):
        if md != 2: continue
        p = co
        tables = struct.unpack_from("<768H", payload, p); p += 1536
        sc, = struct.unpack_from("<I", payload, p); p += 4
        seg0 = b * blockSize // segSize
        lt = struct.unpack_from(f"<{sc}I", payload, p); p += 4*sc
        ct = struct.unpack_from(f"<{sc}I", payload, p); p += 4*sc
        ot = struct.unpack_from(f"<{sc}I", payload, p); p += 4*sc
        rl = struct.unpack_from(f"<{sc}I", payload, p); p += 4*sc
        rc = struct.unpack_from(f"<{sc}I", payload, p); p += 4*sc
        ro = struct.unpack_from(f"<{sc}I", payload, p); p += 4*sc
        cum = [[0]*257 for _ in range(3)]
        for ch in range(3):
            for c in range(256):
                cum[ch][c+1] = cum[ch][c] + tables[ch*256+c]
        lc, cc, oc = p, p + sum(rl), p + sum(rl) + sum(rc)
        for i in range(sc):
            segs[seg0+i] = (rans_dec(payload[lc:lc+rl[i]], lt[i], cum[0]),
                            rans_dec(payload[cc:cc+rc[i]], ct[i], cum[1]),
                            rans_dec(payload[oc:oc+ro[i]], ot[i], cum[2]))
            lc += rl[i]; cc += rc[i]; oc += ro[i]
    for b, (co, cs, os_, md) in enumerate(infos):
        outStart = b * blockSize
        if md == 0:
            out += payload[co:co+os_]
            continue
        if md == 1:
            src = payload[co:]
            ln, cn, on_ = struct.unpack_from("<III", src, 0)
            parse_block(src[12:12+ln], src[12+ln:12+ln+cn],
                        src[12+ln+cn:12+ln+cn+on_], len(out), len(out)+os_, out)
            continue
        seg0 = b * blockSize // segSize
        segEnd = b * blockSize + os_
        nseg = (os_ + segSize - 1) // segSize
        wp = len(out)
        for i in range(nseg):
            lit, code, offS = segs[seg0+i]
            wp = parse_block(lit, code, offS, wp,
                             min(wp + segSize, outStart + os_), out)
    orig = open(orig_path, "rb").read()
    print(f"decoded {len(out)}B want {len(orig)}B  sha match: {hashlib.sha256(out).digest()==hashlib.sha256(orig).digest()}")
    if out != orig:
        i = next(i for i,(a,b_) in enumerate(zip(out, orig)) if a != b_)
        print(f"first diff at byte {i}: got {out[i]:02x} want {orig[i]:02x}")
        print(f"ctx got : {out[i-8:i+8].hex()}")
        print(f"ctx want: {orig[i-8:i+8].hex()}")
        blk = i // blockSize
        print(f"-> block {blk}, mode {infos[blk][3]}")

main(sys.argv[1], sys.argv[2])
