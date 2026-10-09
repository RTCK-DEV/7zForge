#!/usr/bin/env python3
"""Metal版と同じ rANS スキームを Python で往復検証 — 不変条件の特定用。"""
import sys, random

M = 4096
L = 1 << 24
XMAX_SHIFT = 20   # emit while x >= f<<20

def normalize(counts):
    total = sum(counts)
    f = [0]*256
    if total:
        for c in range(256):
            if counts[c]:
                f[c] = max(1, counts[c]*M//total)
        s = sum(f)
        biggest = max(range(256), key=lambda c: f[c])
        diff = s - M
        while diff > 0:
            room = f[biggest] - 1
            take = min(room, diff)
            f[biggest] -= take; diff -= take
            if diff > 0:
                cand = [c for c in range(256) if f[c] > 1]
                if not cand: break
                biggest = max(cand, key=lambda c: f[c])
        for c in range(256):
            if f[c] > 0 and diff < 0:
                f[c] += 1; diff += 1
        while diff < 0:
            f[biggest] += 1; diff += 1
    cum = [0]*257
    for c in range(256):
        cum[c+1] = cum[c] + f[c]
    return f, cum

def enc(data, f, cum):
    x = M
    out = bytearray()
    for s in reversed(data):
        fc, cc = f[s], cum[s]
        while x >= (fc << XMAX_SHIFT):
            out.append(x & 0xFF)
            x >>= 8
        x = (x // fc << 12) + (x % fc) + cc
    out += x.to_bytes(4, "little")
    return bytes(out)

def dec(stream, n, f, cum):
    rp = len(stream) - 4
    x = int.from_bytes(stream[rp:rp+4], "little")
    out = bytearray()
    for _ in range(n):
        slot = x & 0xFFF
        lo, hi = 0, 255
        while lo < hi:
            mid = (lo + hi + 1) // 2
            if cum[mid] <= slot: lo = mid
            else: hi = mid - 1
        fc = cum[lo+1] - cum[lo]
        out.append(lo)
        x = fc * (x >> 12) + slot - cum[lo]
        while x < L:
            rp -= 1
            x = (x << 8) | stream[rp]
    return bytes(out)

random.seed(1)
n_fail = 0
for trial in range(300):
    n = random.choice([100, 1000, 5000])
    if trial % 3 == 0:
        data = bytes(random.choices(range(256), weights=[10 if b < 8 else 1 for b in range(256)], k=n))
    elif trial % 3 == 1:
        data = bytes(random.randrange(256) for _ in range(n))
    else:
        data = bytes([random.randrange(4) for _ in range(n)])
    counts = [0]*256
    for b in data: counts[b] += 1
    f, cum = normalize(counts)
    stream = enc(data, f, cum)
    back = dec(stream, len(data), f, cum)
    if back != data:
        n_fail += 1
        if n_fail <= 3:
            # find first diff
            i = next(i for i, (a, b) in enumerate(zip(back, data)) if a != b)
            print(f"trial {trial}: MISMATCH at {i}/{len(data)} stream={len(stream)}B")
            print(f"  back[{i}]={back[i]} want={data[i]} ctx={data[max(0,i-3):i+4].hex()}")
print(f"{n_fail}/300 failed")
