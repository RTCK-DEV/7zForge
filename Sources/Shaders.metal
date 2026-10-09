#include <metal_stdlib>
#include <metal_atomic>
using namespace metal;

// Z7X3: block-parallel LZSS whose token output is split into three channels
// (literal bytes | token opcodes | match offsets), each order-0 rANS-coded
// per segment with a block-shared normalized model.

struct Z7XParams {
    uint64_t totalSize;
    uint blockSize;    // uncompressed bytes per block
    uint segSize;      // input bytes per GPU thread
    uint numBlocks;
    uint litCap;       // literal channel capacity per seg
    uint codeCap;      // opcode channel capacity per seg
    uint offCap;       // offset channel capacity per seg
    uint ransLitCap;   // rans stream capacity per seg
    uint ransCodeCap;
    uint ransOffCap;
    uint probeDepth;   // 4B-chain depth (4..24)
    uint lazyDepth;    // lookahead distance (0..3)
};

struct Z7XBlockInfo {
    uint64_t compOffset;
    uint compSize;
    uint origSize;
    uint mode;         // 0 stored, 1 raw channels, 2 rans channels
};

struct Z7XSegInfo {     // decode-side per-seg stream locator (mode2 blocks only)
    uint litOff;        // offset into payload of lit rans stream
    uint litLen;
    uint codeOff;
    uint codeLen;
    uint offOff;
    uint offLen;
    uint litTok;        // decoded lit byte count
    uint codeTok;       // decoded opcode byte count
    uint offTok;        // decoded offset byte count
};

constant uint HASH_BITS = 21;
constant uint HASH_SIZE = 1 << HASH_BITS;

inline uint hash4(uint32_t v) {
    uint x = v ^ (v >> 16);
    x *= 0x7feb352du; x ^= x >> 15; x *= 0x846ca68bu; x ^= x >> 16;
    return x >> (32 - HASH_BITS);
}

inline uint32_t load32(device const uchar* p, uint64_t i) {
    return uint32_t(p[i]) | (uint32_t(p[i+1]) << 8) |
           (uint32_t(p[i+2]) << 16) | (uint32_t(p[i+3]) << 24);
}

// ---------------------------------------------------------------------------
// Pass 1: LZ77 dfast+lazy match, emits literal + descriptor channels per segment.
//   Two hash tables (4B / 8B keys) + one-step lazy evaluation:
//   a better match at i+1 defers the match at i into the literal run.
//   dscr token: [n-1 < 128] literal run (n bytes go to lit channel)
//               [128 + (len-4)] + u24 offset
// ---------------------------------------------------------------------------
inline uint hash8(uint64_t v) {
    return uint((v * 889523592379ull) >> (64 - HASH_BITS));
}

inline uint64_t load64(device const uchar* p, uint64_t i) {
    return uint64_t(load32(p, i)) | (uint64_t(load32(p, i + 4)) << 32);
}


// probe both hash chains at `pos` (inserts pos), returns best (len, off).
// score = len - token-cost penalty (far offsets pay 2 extra bytes)
inline uint mscore(uint l, uint64_t d) {
    return l >= 4 ? (d < (1u << 24) ? l : (l > 2 ? l - 2 : 0)) : 0;
}

inline void probe(device const uchar* input, uint64_t pos, uint64_t segEnd,
                  device atomic_uint* heads, device atomic_uint* heads8, uint depth,
                  thread uint& bestL, thread uint64_t& bestOff) {
    bestL = 0; bestOff = 0;
    uint bestS = 0;
    if (pos + 8 <= segEnd) {
        uint h8 = hash8(load64(input, pos));
        uint c8[8];
        c8[0] = atomic_exchange_explicit(&heads8[h8 * 8], uint(pos), memory_order_relaxed);
        for (uint s = 1; s < 8; s++)
            c8[s] = atomic_exchange_explicit(&heads8[h8 * 8 + s], c8[s - 1], memory_order_relaxed);
        for (uint s = 0; s < 8; s++) {
            uint p8 = c8[s];
            if (p8 >= pos) continue;
            uint maxLen = min(uint(segEnd - pos), 127u);
            uint l8 = 0;
            while (l8 < maxLen && input[p8 + l8] == input[pos + l8]) l8++;
            uint s8 = mscore(l8, pos - p8);
            if (s8 > bestS) { bestS = s8; bestL = l8; bestOff = pos - p8; }
        }
    }
    if (pos + 4 > segEnd) { if (bestS < 4) bestL = 0; return; }
    uint h4 = hash4(load32(input, pos));
    uint cands[24];
    cands[0] = atomic_exchange_explicit(&heads[h4 * 24], uint(pos), memory_order_relaxed);
    for (uint s = 1; s < depth; s++)
        cands[s] = atomic_exchange_explicit(&heads[h4 * 24 + s], cands[s - 1], memory_order_relaxed);
    for (uint ci = 0; ci < depth; ci++) {
        if (bestL >= 32) break;   // good-enough cutoff: skip remaining verifies
        uint p4 = cands[ci];
        if (p4 >= pos) continue;
        uint maxLen = min(uint(segEnd - pos), 127u);
        uint l4 = 0;
        while (l4 < maxLen && input[p4 + l4] == input[pos + l4]) l4++;
        uint s4 = mscore(l4, pos - p4);
        if (s4 > bestS) { bestS = s4; bestL = l4; bestOff = pos - p4; }
    }
    if (bestS < 4) bestL = 0;
}

// sparse far-window table: sampled inserts (1/8 positions) keep distant
// candidates alive ~8x longer than the dense LRU chains.
// Measured: ~0.07% ratio gain for +20% kernel time on the 132MB corpus —
// far matches exist but are no longer than near ones. Disabled.


kernel void z7x_compress(device const uchar*  input   [[buffer(0)]],
                         device uchar*        litBuf  [[buffer(1)]],
                         device uchar*        codeBuf [[buffer(2)]],
                         device uchar*        offBuf  [[buffer(3)]],
                         device uint*         litLen  [[buffer(4)]],
                         device uint*         codeLen [[buffer(5)]],
                         device uint*         offLen  [[buffer(6)]],
                         device atomic_uint*  heads   [[buffer(7)]],
                         device atomic_uint*  heads8  [[buffer(8)]],
                         constant Z7XParams&  P       [[buffer(9)]],
                         uint gid [[thread_position_in_grid]])
{
    uint64_t segStart = uint64_t(gid) * P.segSize;
    if (segStart >= P.totalSize) { litLen[gid] = 0; codeLen[gid] = 0; offLen[gid] = 0; return; }
    uint64_t segEnd  = min(segStart + P.segSize, P.totalSize);
    device uchar* lit  = litBuf  + uint64_t(gid) * P.litCap;
    device uchar* code = codeBuf + uint64_t(gid) * P.codeCap;
    device uchar* offB = offBuf  + uint64_t(gid) * P.offCap;
    uint lp = 0, cp = 0, op = 0;
    uint64_t litStart = segStart;
    uint64_t i = segStart;
    uint64_t rep1 = 0, rep2 = 0, rep3 = 0;   // rep-distance LRU (seg-local)

    while (i + 4 <= segEnd) {
        uint l = 0; uint64_t off = 0;
        // direct rep-offset verify first (no hash lookup): rep1..3 pin exact
        // source positions. A strong rep match (>=16) skips probing entirely.
        uint64_t reps[3] = {rep1, rep2, rep3};
        for (int r = 0; r < 3; r++) {
            if (reps[r] && reps[r] <= i) {
                uint ml = min(uint(segEnd - i), 127u), rl = 0;
                while (rl < ml && input[i - reps[r] + rl] == input[i + rl]) rl++;
                if (rl > l) { l = rl; off = reps[r]; }
            }
        }
        if (l < 16) {   // weak/absent rep → full hash probe
            uint pl; uint64_t po;
            probe(input, i, segEnd, heads, heads8, P.probeDepth, pl, po);
            // prefer the rep when the probed match isn't worth ~2B more
            if (mscore(pl, po) > l + 2) { l = pl; off = po; }
        }
        if (l < 4) { i++; continue; }

        // lazy: a strictly better match at i+1 or i+2 defers this one
        // effective score: token-cost penalty + rep bonus (~2B cheaper)
        uint s0 = mscore(l, off) + (off == rep1 || off == rep2 || off == rep3 ? 2u : 0u);
        if (P.lazyDepth >= 1) {
            uint l2; uint64_t o2;
            probe(input, i + 1, segEnd, heads, heads8, P.probeDepth, l2, o2);
            if (mscore(l2, o2) > s0) { i++; continue; }
        }
        if (P.lazyDepth >= 2 && l <= 8) {
            uint l3; uint64_t o3;
            probe(input, i + 2, segEnd, heads, heads8, P.probeDepth, l3, o3);
            if (mscore(l3, o3) > s0) { i += 2; continue; }
        }
        if (P.lazyDepth >= 3 && l <= 6) {
            uint l4m; uint64_t o4;
            probe(input, i + 3, segEnd, heads, heads8, P.probeDepth, l4m, o4);
            if (mscore(l4m, o4) > s0) { i += 3; continue; }
        }

        // backward extension: if the match source still aligns one byte
        // earlier, absorb a pending literal into the match (litStart bounds;
        // off < i required to keep the source index valid; cap l at 127 so
        // the emitted code stays below the rep/far escape range)
        while (i > litStart && off < i && l < 127 && input[i - 1] == input[i - 1 - off]) { i--; l++; }

        while (litStart < i) {
            uint n = min(uint(i - litStart), 127u);
            code[cp++] = uchar(n - 1);
            for (uint k = 0; k < n; k++) lit[lp++] = input[litStart + k];
            litStart += n;
        }
        // rep codes: 255=rep1 254=rep2 253=rep3 (LRU, seg-local)
        uint repCode = 0;
        if (off == rep1) repCode = 255;
        else if (off == rep2) repCode = 254;
        else if (off == rep3) repCode = 253;
        if (repCode) {
            code[cp++] = uchar(repCode);
            code[cp++] = uchar(l - 4);
            uint64_t t1 = rep1, t2 = rep2;
            if (repCode == 255)      { /* rep1 stays */ }
            else if (repCode == 254) { rep2 = t1; rep1 = off; }
            else                     { rep3 = t2; rep2 = t1; rep1 = off; }
        } else {
            if (off < (1u << 24)) {
                code[cp++] = uchar(128 + (l - 4));     // 128..251 → len 4..127
                offB[op++] = uchar(off & 0xFF);
                offB[op++] = uchar((off >> 8) & 0xFF);
                offB[op++] = uchar((off >> 16) & 0xFF);
            } else {
                code[cp++] = 252;                      // far match: u32 offset
                code[cp++] = uchar(l - 4);
                offB[op++] = uchar(off & 0xFF);
                offB[op++] = uchar((off >> 8) & 0xFF);
                offB[op++] = uchar((off >> 16) & 0xFF);
                offB[op++] = uchar((off >> 24) & 0xFF);
            }
            rep3 = rep2; rep2 = rep1; rep1 = off;
        }
        i += l;
        litStart = i;
    }
    while (i < segEnd) i++;
    while (litStart < i) {
        uint n = min(uint(i - litStart), 127u);
        code[cp++] = uchar(n - 1);
        for (uint k = 0; k < n; k++) lit[lp++] = input[litStart + k];
        litStart += n;
    }
    litLen[gid] = lp;
    codeLen[gid] = cp;
    offLen[gid] = op;
}

// ---------------------------------------------------------------------------
// Optimal-parse variant: probe EVERY position, then per-seg backward DP with
// a fixed bit-cost model (lit 8.0b, code 5.0b, off-byte 7.3b, far +16b), then
// emit the chosen path. ~4-5x the probe cost of greedy; buys the last ~10%.
// scratch layout per seg: lenArr u8 | offArr u32 | cost u32  (9 B/pos)
// ---------------------------------------------------------------------------
kernel void z7x_dp(device const uchar*  input   [[buffer(0)]],
                   device uchar*        litBuf  [[buffer(1)]],
                   device uchar*        codeBuf [[buffer(2)]],
                   device uchar*        offBuf  [[buffer(3)]],
                   device uint*         litLen  [[buffer(4)]],
                   device uint*         codeLen [[buffer(5)]],
                   device uint*         offLen  [[buffer(6)]],
                   device atomic_uint*  heads   [[buffer(7)]],
                   device atomic_uint*  heads8  [[buffer(8)]],
                   device uchar*        lenArr  [[buffer(9)]],
                   device uint*         offArr  [[buffer(10)]],
                   device uint*         costArr [[buffer(11)]],
                   constant Z7XParams&  P       [[buffer(12)]],
                   uint gid [[thread_position_in_grid]])
{
    uint64_t segStart = uint64_t(gid) * P.segSize;
    if (segStart >= P.totalSize) { litLen[gid] = 0; codeLen[gid] = 0; offLen[gid] = 0; return; }
    uint64_t segEnd = min(segStart + P.segSize, P.totalSize);
    uint n = uint(segEnd - segStart);
    device uchar* lenA  = lenArr + uint64_t(gid) * P.segSize;
    device uint*  offA  = offArr + uint64_t(gid) * P.segSize;
    device uint*  costA = costArr + uint64_t(gid) * P.segSize;

    // Phase A: probe all positions
    for (uint i = 0; i < n; i++) {
        uint l; uint64_t o;
        probe(input, segStart + i, segEnd, heads, heads8, P.probeDepth, l, o);
        if (l >= 4) { lenA[i] = uchar(l); offA[i] = uint(o); }
        else lenA[i] = 0;
    }

    // Phase B: backward DP. Fixed-point bits x256.
    const uint LITC = 2048;                 // ~8.0 bits
    const uint CODEC = 1280;                // ~5.0 bits
    const uint OFFB = 1869;                 // ~7.3 bits per offset byte
    // costA index n is never written (it would clobber the next seg's slot);
    // reads past the seg end contribute zero (DP boundary)
    for (uint i = n; i-- > 0;) {
        uint best = LITC + (i + 1 < n ? costA[i + 1] : 0u);
        uint bl = 0;
        uint l = lenA[i];
        if (l >= 4) {
            uint64_t o = offA[i];
            uint mc = CODEC + (o < (1u << 24) ? 3u : 4u) * OFFB;
            for (uint cand = 4; cand <= l; cand++) {
                uint tc = mc + (i + cand < n ? costA[i + cand] : 0u);
                if (tc < best) { best = tc; bl = cand; }
            }
        }
        costA[i] = best;
        lenA[i] = uchar(bl);   // reuse lenA as the choice array
    }

    // Phase C: emit chosen path
    device uchar* lit  = litBuf  + uint64_t(gid) * P.litCap;
    device uchar* code = codeBuf + uint64_t(gid) * P.codeCap;
    device uchar* offB = offBuf  + uint64_t(gid) * P.offCap;
    uint lp = 0, cp = 0, op = 0;
    uint64_t litStart = segStart;
    uint64_t i = segStart;
    uint64_t rep1 = 0, rep2 = 0, rep3 = 0;
    while (i < segEnd) {
        uint l = lenA[i - segStart];
        if (l == 0) { i++; continue; }
        uint64_t off = offA[i - segStart];
        while (litStart < i) {
            uint nn = min(uint(i - litStart), 127u);
            code[cp++] = uchar(nn - 1);
            for (uint k = 0; k < nn; k++) lit[lp++] = input[litStart + k];
            litStart += nn;
        }
        uint repCode = 0;
        if (off == rep1) repCode = 255;
        else if (off == rep2) repCode = 254;
        else if (off == rep3) repCode = 253;
        if (repCode) {
            code[cp++] = uchar(repCode);
            code[cp++] = uchar(l - 4);
            uint64_t t1 = rep1, t2 = rep2;
            if (repCode == 255)      { }
            else if (repCode == 254) { rep2 = t1; rep1 = off; }
            else                     { rep3 = t2; rep2 = t1; rep1 = off; }
        } else if (off < (1u << 24)) {
            code[cp++] = uchar(128 + (l - 4));
            offB[op++] = uchar(off & 0xFF);
            offB[op++] = uchar((off >> 8) & 0xFF);
            offB[op++] = uchar((off >> 16) & 0xFF);
            rep3 = rep2; rep2 = rep1; rep1 = off;
        } else {
            code[cp++] = 252;
            code[cp++] = uchar(l - 4);
            offB[op++] = uchar(off & 0xFF);
            offB[op++] = uchar((off >> 8) & 0xFF);
            offB[op++] = uchar((off >> 16) & 0xFF);
            offB[op++] = uchar((off >> 24) & 0xFF);
            rep3 = rep2; rep2 = rep1; rep1 = off;
        }
        i += l;
        litStart = i;
    }
    while (litStart < segEnd) {
        uint nn = min(uint(segEnd - litStart), 127u);
        code[cp++] = uchar(nn - 1);
        for (uint k = 0; k < nn; k++) lit[lp++] = input[litStart + k];
        litStart += nn;
    }
    litLen[gid] = lp;
    codeLen[gid] = cp;
    offLen[gid] = op;
}

// ---------------------------------------------------------------------------
// Pass 2: block-shared order-0 histogram over the three channels.
//   hist[blk*768 + 0..255] = lit, [+256..511] = code, [+512..767] = offset.
// ---------------------------------------------------------------------------
kernel void z7x_hist(device const uchar*  litBuf  [[buffer(0)]],
                     device const uchar*  codeBuf [[buffer(1)]],
                     device const uchar*  offBuf  [[buffer(2)]],
                     device const uint*   litLen  [[buffer(3)]],
                     device const uint*   codeLen [[buffer(4)]],
                     device const uint*   offLen  [[buffer(5)]],
                     device atomic_uint*  hist    [[buffer(6)]],
                     constant Z7XParams&  P       [[buffer(7)]],
                     uint gid [[thread_position_in_grid]])
{
    uint blk = gid * P.segSize / P.blockSize;
    device atomic_uint* h = hist + blk * 768;
    device const uchar* lit  = litBuf  + uint64_t(gid) * P.litCap;
    device const uchar* code = codeBuf + uint64_t(gid) * P.codeCap;
    device const uchar* off  = offBuf  + uint64_t(gid) * P.offCap;
    uint nl = litLen[gid], nc = codeLen[gid], no = offLen[gid];
    for (uint i = 0; i < nl; i++)
        atomic_fetch_add_explicit(&h[lit[i]], 1u, memory_order_relaxed);
    for (uint i = 0; i < nc; i++)
        atomic_fetch_add_explicit(&h[256 + code[i]], 1u, memory_order_relaxed);
    for (uint i = 0; i < no; i++)
        atomic_fetch_add_explicit(&h[512 + off[i]], 1u, memory_order_relaxed);
}

// normalize 256 counts to sum==4096 with min-1 for present symbols
inline void norm256(device const uint* h, thread ushort* f, thread uint* cum) {
    uint total = 0;
    for (uint c = 0; c < 256; c++) total += h[c];
    if (total == 0) { for (uint c = 0; c < 256; c++) f[c] = 0; }
    else {
        uint sum = 0, biggest = 0, bigv = 0;
        for (uint c = 0; c < 256; c++) {
            f[c] = h[c] ? ushort(max(1u, uint(uint64_t(h[c]) * 4096u / total))) : 0;
            sum += f[c];
            if (f[c] > bigv) { bigv = f[c]; biggest = c; }
        }
        int diff = int(sum) - 4096;
        while (diff > 0) {
            uint room = uint(f[biggest]) - 1;
            uint take = min(room, uint(diff));
            f[biggest] = ushort(uint(f[biggest]) - take);
            diff -= int(take);
            if (diff > 0) {
                bigv = 0;
                for (uint c = 0; c < 256; c++)
                    if (f[c] > 1 && f[c] > bigv) { bigv = f[c]; biggest = c; }
                if (bigv == 0) break;
            }
        }
        // deficit: spread +1 across present symbols before dumping rest on biggest
        for (uint c = 0; c < 256 && diff < 0; c++)
            if (f[c] > 0) { f[c]++; diff++; }
        while (diff < 0) { f[biggest]++; diff++; }
    }
    cum[0] = 0;
    for (uint c = 0; c < 256; c++) cum[c + 1] = cum[c] + f[c];
}

// single-stream rANS encode, backward scan, emissions forward + u32 state at tail.
// Writes are clamped to `cap`; the return value is the true stream length and may
// exceed cap — callers must fall back to raw channels for that block in that case.
inline uint rans_enc(device const uchar* src, uint n, uint cap,
                     thread ushort* f, thread uint* cum, device uchar* out) {
    uint wp = 0;
    uint64_t x = 4096;
    for (uint i = n; i > 0; i--) {
        uchar s = src[i - 1];
        uint fc = f[s], cc = cum[s];
        while (x >= (uint64_t(fc) << 20)) { if (wp < cap) out[wp] = uchar(x & 0xFF); wp++; x >>= 8; }
        x = ((x / fc) << 12) + (x % fc) + cc;
    }
    if (wp + 4 <= cap) {
        out[wp] = uchar(x & 0xFF);        out[wp + 1] = uchar((x >> 8) & 0xFF);
        out[wp + 2] = uchar((x >> 16) & 0xFF); out[wp + 3] = uchar((x >> 24) & 0xFF);
    }
    return wp + 4;
}

// Pass 3: rANS-encode each seg's three channels (block-shared model).
kernel void z7x_ransenc(device const uchar*  litBuf   [[buffer(0)]],
                        device const uchar*  codeBuf  [[buffer(1)]],
                        device const uchar*  offBuf   [[buffer(2)]],
                        device const uint*   litLen   [[buffer(3)]],
                        device const uint*   codeLen  [[buffer(4)]],
                        device const uint*   offLen   [[buffer(5)]],
                        device const uint*   hist     [[buffer(6)]],
                        device ushort*       tables   [[buffer(7)]],  // numBlocks*768
                        device uchar*        ransLit  [[buffer(8)]],
                        device uchar*        ransCode [[buffer(9)]],
                        device uchar*        ransOff  [[buffer(10)]],
                        device uint*         ransLitLen  [[buffer(11)]],
                        device uint*         ransCodeLen [[buffer(12)]],
                        device uint*         ransOffLen  [[buffer(13)]],
                        constant Z7XParams&  P        [[buffer(14)]],
                        uint gid [[thread_position_in_grid]])
{
    uint blk = gid * P.segSize / P.blockSize;
    device const uint* h = hist + blk * 768;
    ushort f[768];
    uint cumA[257], cumB[257], cumC[257];
    norm256(h, f, cumA);
    norm256(h + 256, f + 256, cumB);
    norm256(h + 512, f + 512, cumC);
    if (gid * P.segSize == uint64_t(blk) * P.blockSize) {
        for (uint c = 0; c < 768; c++) tables[blk * 768 + c] = f[c];
    }
    uint nl = litLen[gid], nc = codeLen[gid], no = offLen[gid];
    device const uchar* lit  = litBuf  + uint64_t(gid) * P.litCap;
    device const uchar* code = codeBuf + uint64_t(gid) * P.codeCap;
    device const uchar* off  = offBuf  + uint64_t(gid) * P.offCap;
    ransLitLen[gid]  = rans_enc(lit, nl, P.ransLitCap, f, cumA,
                                ransLit + uint64_t(gid) * P.ransLitCap);
    ransCodeLen[gid] = rans_enc(code, nc, P.ransCodeCap, f + 256, cumB,
                                ransCode + uint64_t(gid) * P.ransCodeCap);
    ransOffLen[gid]  = rans_enc(off, no, P.ransOffCap, f + 512, cumC,
                                ransOff + uint64_t(gid) * P.ransOffCap);
}

// ---------------------------------------------------------------------------
// Decode pass A: rANS-decode each seg's lit + dscr streams (mode2 blocks only).
// ---------------------------------------------------------------------------
inline void rans_dec(device const uchar* src, uint streamLen, uint nSym,
                     thread uint* cum, device uchar* out) {
    uint rp = streamLen - 4;
    uint64_t x = uint64_t(src[rp]) | (uint64_t(src[rp+1]) << 8) |
                 (uint64_t(src[rp+2]) << 16) | (uint64_t(src[rp+3]) << 24);
    for (uint i = 0; i < nSym; i++) {
        uint slot = uint(x & 0xFFF);
        uint lo = 0, hi = 255;
        while (lo < hi) {
            uint mid = (lo + hi + 1) / 2;
            if (cum[mid] <= slot) lo = mid; else hi = mid - 1;
        }
        uint f = cum[lo + 1] - cum[lo];
        out[i] = uchar(lo);
        x = uint64_t(f) * (x >> 12) + (x & 0xFFF) - cum[lo];
        while (x < (1u << 24) && rp > 0) { rp--; x = (x << 8) | src[rp]; }
    }
}

kernel void z7x_ransdec(device const uchar*      payload  [[buffer(0)]],
                        device const Z7XSegInfo* segs     [[buffer(1)]],
                        device const ushort*     tables   [[buffer(2)]],
                        device const uint*       litOffs  [[buffer(3)]],
                        device const uint*       codeOffs [[buffer(4)]],
                        device const uint*       offOffs  [[buffer(5)]],
                        device const uint*       modeFlag [[buffer(6)]],
                        device uchar*            litScratch [[buffer(7)]],
                        device uchar*            codeScratch [[buffer(8)]],
                        device uchar*            offScratch  [[buffer(9)]],
                        constant Z7XParams&      P        [[buffer(10)]],
                        uint gid [[thread_position_in_grid]])
{
    uint blk = gid * P.segSize / P.blockSize;
    if (modeFlag[blk] != 2) return;
    device const ushort* ft = tables + blk * 768;
    uint cumA[257], cumB[257], cumC[257];
    cumA[0] = cumB[0] = cumC[0] = 0;
    for (uint c = 0; c < 256; c++) {
        cumA[c + 1] = cumA[c] + ft[c];
        cumB[c + 1] = cumB[c] + ft[256 + c];
        cumC[c + 1] = cumC[c] + ft[512 + c];
    }
    Z7XSegInfo sg = segs[gid];
    rans_dec(payload + sg.litOff, sg.litLen, sg.litTok, cumA, litScratch + litOffs[gid]);
    rans_dec(payload + sg.codeOff, sg.codeLen, sg.codeTok, cumB, codeScratch + codeOffs[gid]);
    rans_dec(payload + sg.offOff, sg.offLen, sg.offTok, cumC, offScratch + offOffs[gid]);
}

// ---------------------------------------------------------------------------
// Decode pass B1: token->srcPos map, one thread per SEGMENT (mode2 only).
//   For every output position p in the seg's range:
//     literal byte -> srcPos[p] = LIT | global litScratch index
//     match byte   -> srcPos[p] = absolute source output position
// ---------------------------------------------------------------------------
constant uint LIT_FLAG = 1u << 31;

kernel void z7x_parse(device const uchar*       codeScratch [[buffer(0)]],
                      device const uchar*       offScratch  [[buffer(1)]],
                      device uint*              srcPos      [[buffer(2)]],
                      device const uint*        litOffs     [[buffer(3)]],
                      device const uint*        codeOffs    [[buffer(4)]],
                      device const uint*        offOffs     [[buffer(5)]],
                      device const uint*        modeFlag    [[buffer(6)]],
                      constant Z7XParams&       P           [[buffer(7)]],
                      uint gid [[thread_position_in_grid]])
{
    uint64_t segStart = uint64_t(gid) * P.segSize;
    if (segStart >= P.totalSize) return;
    uint64_t segEnd = min(segStart + P.segSize, P.totalSize);
    uint blk = uint(segStart / P.blockSize);
    if (modeFlag[blk] != 2) return;
    device const uchar* code = codeScratch + codeOffs[gid];
    device const uchar* offS = offScratch + offOffs[gid];
    uint litBase = litOffs[gid];
    uint rp = 0, op = 0;
    uint64_t lp = 0;
    uint64_t wp = segStart;
    uint64_t rep1 = 0, rep2 = 0, rep3 = 0;
    while (wp < segEnd) {
        uint c = code[rp++];
        if (c < 128) {
            uint n = c + 1;
            for (uint k = 0; k < n; k++)
                srcPos[wp + k] = LIT_FLAG | (litBase + uint(lp) + k);
            lp += n; wp += n;
        } else {
            uint l; uint64_t off;
            if (c >= 253) {
                l = uint(code[rp++]) + 4;
                uint64_t t1 = rep1, t2 = rep2;
                if (c == 255)      { off = rep1; }
                else if (c == 254) { off = rep2; rep2 = t1; rep1 = off; }
                else               { off = rep3; rep3 = t2; rep2 = t1; rep1 = off; }
            } else if (c == 252) {
                l = uint(code[rp++]) + 4;
                off = uint(offS[op]) | (uint(offS[op + 1]) << 8) |
                      (uint(offS[op + 2]) << 16) | (uint(offS[op + 3]) << 24);
                op += 4;
                rep3 = rep2; rep2 = rep1; rep1 = off;
            } else {
                l = (c - 128) + 4;
                off = uint(offS[op]) | (uint(offS[op + 1]) << 8) | (uint(offS[op + 2]) << 16);
                op += 3;
                rep3 = rep2; rep2 = rep1; rep1 = off;
            }
            uint64_t s = wp - off;
            for (uint k = 0; k < l; k++) srcPos[wp + k] = uint(s + k);
            wp += l;
        }
    }
}

// one pointer-doubling hop: srcPos[p] = srcPos[srcPos[p]] until literal.
kernel void z7x_chase(device uint*           srcPos     [[buffer(0)]],
                      device atomic_uint*    unresolved [[buffer(1)]],
                      constant Z7XParams&    P          [[buffer(2)]],
                      uint gid [[thread_position_in_grid]])
{
    if (uint64_t(gid) >= P.totalSize) return;
    uint q = srcPos[gid];
    if (q & LIT_FLAG) return;
    uint r = srcPos[q];
    srcPos[gid] = r;
    if (!(r & LIT_FLAG)) atomic_fetch_add_explicit(unresolved, 1u, memory_order_relaxed);
}

// materialize mode2 positions from litScratch; mode0/1 handled by seq kernel.
kernel void z7x_materialize(device uchar*             output     [[buffer(0)]],
                            device const uchar*       litScratch [[buffer(1)]],
                            device const uint*        srcPos     [[buffer(2)]],
                            device const uint*        modeFlag   [[buffer(3)]],
                            constant Z7XParams&       P          [[buffer(4)]],
                            uint gid [[thread_position_in_grid]])
{
    if (uint64_t(gid) >= P.totalSize) return;
    uint blk = uint(uint64_t(gid) / P.blockSize);
    if (modeFlag[blk] != 2) return;
    output[gid] = litScratch[srcPos[gid] & ~LIT_FLAG];
}

// sequential fallback for stored (mode0) and raw-channel (mode1) blocks,
// one thread per block — rare path (incompressible data / rans overflow).
kernel void z7x_decompress_seq(device const uchar*       payload    [[buffer(0)]],
                               device uchar*             output     [[buffer(1)]],
                               device const Z7XBlockInfo* infos     [[buffer(2)]],
                               device const uint*        modeFlag   [[buffer(3)]],
                               constant Z7XParams&       P          [[buffer(4)]],
                               uint gid [[thread_position_in_grid]])
{
    if (gid >= P.numBlocks || modeFlag[gid] == 2) return;
    Z7XBlockInfo info = infos[gid];
    uint64_t outStart = uint64_t(gid) * P.blockSize;
    uint64_t outEnd   = outStart + info.origSize;
    device const uchar* src = payload + info.compOffset;

    if (info.mode == 0) {
        for (uint k = 0; k < info.origSize; k++) output[outStart + k] = src[k];
        return;
    }
    uint litN = uint(src[0]) | (uint(src[1]) << 8) | (uint(src[2]) << 16) | (uint(src[3]) << 24);
    uint codeN = uint(src[4]) | (uint(src[5]) << 8) | (uint(src[6]) << 16) | (uint(src[7]) << 24);
    device const uchar* lit = src + 12;
    device const uchar* code = src + 12 + litN;
    device const uchar* offS = src + 12 + litN + codeN;
    uint rp = 0, op = 0;
    uint64_t lp = 0;
    uint64_t wp = outStart;
    uint64_t rep1 = 0, rep2 = 0, rep3 = 0;
    while (wp < outEnd) {
        uint c = code[rp++];
        if (c < 128) {
            uint n = c + 1;
            for (uint k = 0; k < n; k++) output[wp + k] = lit[lp + k];
            lp += n; wp += n;
        } else {
            uint l; uint64_t off;
            if (c >= 253) {
                l = uint(code[rp++]) + 4;
                uint64_t t1 = rep1, t2 = rep2;
                if (c == 255)      { off = rep1; }
                else if (c == 254) { off = rep2; rep2 = t1; rep1 = off; }
                else               { off = rep3; rep3 = t2; rep2 = t1; rep1 = off; }
            } else if (c == 252) {
                l = uint(code[rp++]) + 4;
                off = uint(offS[op]) | (uint(offS[op + 1]) << 8) |
                      (uint(offS[op + 2]) << 16) | (uint(offS[op + 3]) << 24);
                op += 4;
                rep3 = rep2; rep2 = rep1; rep1 = off;
            } else {
                l = (c - 128) + 4;
                off = uint(offS[op]) | (uint(offS[op + 1]) << 8) | (uint(offS[op + 2]) << 16);
                op += 3;
                rep3 = rep2; rep2 = rep1; rep1 = off;
            }
            uint64_t s = wp - off;
            for (uint k = 0; k < l; k++) { output[wp] = output[s + k]; wp++; }
        }
    }
}
