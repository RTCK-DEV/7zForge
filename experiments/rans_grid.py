#!/usr/bin/env python3
"""rANS pull-condition を総当たり検証 — 正しい不変条件を実験で特定する。"""
import random

M = 4096

def normalize(counts):
    total = sum(counts)
    f = [0]*256
    for c in range(256):
        if counts[c]:
            f[c] = max(1, counts[c]*M//total)
    s = sum(f)
    biggest = max(range(256), key=lambda c: f[c])
    diff = s - M
    while diff > 0:
        take = min(f[biggest]-1, diff); f[biggest] -= take; diff -= take
        if diff > 0:
            cand = [c for c in range(256) if f[c] > 1]
            if not cand: break
            biggest = max(cand, key=lambda c: f[c])
    for c in range(256):
        if f[c] > 0 and diff < 0: f[c] += 1; diff += 1
    while diff < 0: f[biggest] += 1; diff += 1
    cum = [0]*257
    for c in range(256): cum[c+1] = cum[c] + f[c]
    return f, cum

def enc(data, f, cum, emit_shift):
    x = M
    out = bytearray()
    for s in reversed(data):
        fc, cc = f[s], cum[s]
        while x >= (fc << emit_shift):
            out.append(x & 0xFF); x >>= 8
        x = (x // fc << 12) + (x % fc) + cc
    out += x.to_bytes(4, "little")
    return bytes(out)

def dec(stream, n, f, cum, pull_cond):
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
        fc = cum[lo+1]-cum[lo]
        out.append(lo)
        x = fc*(x >> 12) + slot - cum[lo]
        while pull_cond(x, fc) and rp > 0:
            rp -= 1
            x = (x << 8) | stream[rp]
    return bytes(out)

random.seed(1)
corpora = []
for t in range(60):
    n = random.choice([50, 300, 2000])
    if t % 3 == 0:
        corpora.append(bytes(random.choices(range(256), weights=[10 if b<8 else 1 for b in range(256)], k=n)))
    elif t % 3 == 1:
        corpora.append(bytes(random.randrange(256) for _ in range(n)))
    else:
        corpora.append(bytes(random.randrange(3) for _ in range(n)))

configs = [
    ("L=2^24, emit f<<20", 20, lambda x, f: x < (1<<24)),
    ("L=2^20, emit f<<20", 20, lambda x, f: x < (1<<20)),
    ("L=2^16, emit f<<20", 20, lambda x, f: x < (1<<16)),
    ("pull x < f<<20",     20, lambda x, f: x < (f<<20)),
    ("pull x < f<<12",     20, lambda x, f: x < (f<<12)),
    ("emit f<<24 L=2^24",  24, lambda x, f: x < (1<<24)),
]
for name, es, cond in configs:
    fails = 0
    for data in corpora:
        counts = [0]*256
        for b in data: counts[b] += 1
        f, cum = normalize(counts)
        try:
            back = dec(enc(data, f, cum, es), len(data), f, cum, cond)
        except Exception:
            fails += 1; continue
        if back != data: fails += 1
    print(f"{name:22s}: {fails}/{len(corpora)} failed")
