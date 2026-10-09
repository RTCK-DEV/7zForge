#!/usr/bin/env python3
"""Z7X トークン列の order-0 エントロピー解析 — rANS 化の期待値を実装前に推定する。"""
import sys, os
import numpy as np

CAP = 32 << 20

def entropy_bits(b):
    if not b:
        return 0.0
    c = np.bincount(np.frombuffer(b, dtype=np.uint8), minlength=256)
    p = c[c > 0] / c.sum()
    return float(-np.sum(p * np.log2(p)))

def main():
    path = sys.argv[1]
    orig_path = sys.argv[2] if len(sys.argv) > 2 else None
    d = open(path, "rb").read(CAP)
    n = len(d)
    lit = bytearray(); ctrl = bytearray(); olo = bytearray(); omid = bytearray(); ohi = bytearray()
    mlen = 0
    i = 0
    while i < n:
        c = d[i]; i += 1
        if c < 128:
            run = c + 1
            lit += d[i:i+run]
            ctrl.append(c)
            i += run
        else:
            if i + 2 >= n:
                break
            ctrl.append(c)
            mlen += c - 128 + 4
            olo.append(d[i]); omid.append(d[i+1]); ohi.append(d[i+2]); i += 3

    H_all  = entropy_bits(d[:i])
    H_lit  = entropy_bits(lit)
    H_ctrl = entropy_bits(ctrl)
    H_lo   = entropy_bits(olo)
    H_mid  = entropy_bits(omid)
    H_hi   = entropy_bits(ohi)
    nl, nc, no = len(lit), len(ctrl), len(olo)

    print(f"tokens: {i} bytes parsed (lit {nl} ctrl {nc} offs {no}x3, マッチカバー {mlen} B)")
    print(f"order-0 entropy:")
    print(f"  all-in-one : {H_all:.2f} bits/B -> rANS単一 = {i*H_all/8:,.0f} B")
    print(f"  literal    : {H_lit:.2f} bits/B -> {nl*H_lit/8:,.0f} B")
    print(f"  control    : {H_ctrl:.2f} bits/B -> {nc*H_ctrl/8:,.0f} B")
    print(f"  off_lo     : {H_lo:.2f} bits/B -> {no*H_lo/8:,.0f} B")
    print(f"  off_mid    : {H_mid:.2f} bits/B -> {no*H_mid/8:,.0f} B")
    print(f"  off_hi     : {H_hi:.2f} bits/B -> {no*H_hi/8:,.0f} B")
    single = i * H_all / 8
    split = nl*H_lit/8 + nc*H_ctrl/8 + no*(H_lo+H_mid+H_hi)/8
    print(f"予測サイズ: 単一rANS {single:,.0f} B / 分割rANS {split:,.0f} B (現 {i:,} B)")
    if orig_path:
        orig = os.path.getsize(orig_path)
        print(f"予測圧縮率: 単一 {orig/single:.2f}x / 分割 {orig/split:.2f}x (現 {orig/i:.2f}x)")

if __name__ == "__main__":
    main()
