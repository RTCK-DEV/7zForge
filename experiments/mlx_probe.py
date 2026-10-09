#!/usr/bin/env python3
"""
MLX neural compression probe — ML (GPU/ANE 系演算) で圧縮は速くなるのか?の実測検証。

問い:
  A) Transformer が byte 列を予測する速度は CPU コーデックに敵うか
     - "encode 側": teacher forcing で全位置を並列予測可能 → GPU 並列で意外と速い?
     - "decode 側": 圧縮データ復元は逐次 (前のバイトが確定しないと次の分布が出ない)
  B) 圧縮率 (bits/byte) は CPU コーデックに勝てるか

結論は数字で出す。使い方: python mlx_probe.py [text_file]
"""
import sys, time, zlib, lzma
import numpy as np
import mlx.core as mx
import mlx.nn as nn
import mlx.optimizers as optim

DIM, LAYERS, HEADS, SEQ, VOCAB = 128, 4, 4, 256, 256
TRAIN_STEPS, BATCH = 120, 32


class Block(nn.Module):
    def __init__(self):
        super().__init__()
        self.attn = nn.MultiHeadAttention(DIM, HEADS)
        self.ln1 = nn.LayerNorm(DIM)
        self.ln2 = nn.LayerNorm(DIM)
        self.mlp = nn.Sequential(nn.Linear(DIM, 4 * DIM), nn.GELU(), nn.Linear(4 * DIM, DIM))

    def __call__(self, x, mask):
        x = x + self.attn(self.ln1(x), self.ln1(x), self.ln1(x), mask=mask)
        return x + self.mlp(self.ln2(x))


class TinyTransformer(nn.Module):
    def __init__(self):
        super().__init__()
        self.emb = nn.Embedding(VOCAB, DIM)
        self.pos = nn.Embedding(SEQ, DIM)
        self.blocks = [Block() for _ in range(LAYERS)]
        self.out = nn.Linear(DIM, VOCAB)

    def __call__(self, ids):
        L = ids.shape[1]
        x = self.emb(ids) + self.pos(mx.arange(L))[None, :]
        mask = nn.MultiHeadAttention.create_additive_causal_mask(L)
        for b in self.blocks:
            x = b(x, mask)
        return self.out(x)


def loss_fn(model, x):
    logits = model(x[:, :-1]).reshape(-1, VOCAB)
    return nn.losses.cross_entropy(logits, x[:, 1:].reshape(-1), reduction="mean")


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/History.txt"
    raw = np.frombuffer(open(path, "rb").read(), dtype=np.uint8)
    if len(raw) < 1 << 15:
        raw = np.tile(raw, 8)
    data = raw[: 1 << 20]  # cap 1MB
    n = len(data)
    print(f"== corpus: {path} ({n/1024:.0f} KiB)")
    print(f"== device: {mx.default_device()}")

    # --- CPU baselines -------------------------------------------------------
    t = time.perf_counter()
    zc = zlib.compress(data.tobytes(), 6)
    z_t = (time.perf_counter() - t) * 1000
    t = time.perf_counter()
    lc = lzma.compress(data.tobytes(), preset=6)
    l_t = (time.perf_counter() - t) * 1000
    t = time.perf_counter()
    zlib.decompress(zc)
    zd_t = (time.perf_counter() - t) * 1000
    print(f"zlib-6   : {len(zc)/n:.3f} ratio | comp {z_t:8.1f} ms ({n/1e6/(z_t/1e3):7.1f} MB/s) | decomp {zd_t:7.1f} ms")
    print(f"lzma-6   : {len(lc)/n:.3f} ratio | comp {l_t:8.1f} ms ({n/1e6/(l_t/1e3):7.1f} MB/s)")

    # --- quick train ---------------------------------------------------------
    model = TinyTransformer()
    mx.eval(model.parameters())
    opt = optim.Adam(learning_rate=3e-3)
    vg = nn.value_and_grad(model, loss_fn)
    starts = np.random.randint(0, n - SEQ - 1, size=(TRAIN_STEPS, BATCH))
    t0 = time.perf_counter()
    for i, s in enumerate(starts):
        batch = np.stack([data[j : j + SEQ + 1] for j in s])
        x = mx.array(batch)
        loss, grad = vg(model, x)
        opt.update(model, grad)
        mx.eval(model.parameters(), loss)
    print(f"== trained {TRAIN_STEPS} steps in {time.perf_counter()-t0:.1f}s (tiny model, few min corpus — 参考値)")

    # --- ratio estimate (bits/byte from cross-entropy) -----------------------
    tot_bpb, tot_n = 0.0, 0
    for s in range(0, n - SEQ - 1, SEQ):
        x = mx.array(data[s : s + SEQ + 1][None, :])
        l = loss_fn(model, x)
        mx.eval(l)
        tot_bpb += float(l) * SEQ
        tot_n += SEQ
    bpb = tot_bpb / tot_n / np.log(2)
    print(f"ML ratio : {bpb:.3f} bits/byte -> 理論圧縮率 {bpb/8:.3f} (zlib {len(zc)/n:.3f} / lzma {len(lc)/n:.3f})")

    # --- A) encode-side throughput: teacher-forced = parallel -----------------
    chunk = 1 << 17  # 128KiB per forward
    t = time.perf_counter()
    done = 0
    for s in range(0, n - SEQ - 1, chunk):
        nseq = min(chunk, n - SEQ - 1 - s)
        xs = np.stack([data[s + i : s + i + SEQ + 1] for i in range(0, nseq, SEQ)])
        l = loss_fn(model, mx.array(xs))
        mx.eval(l)
        done += len(xs) * SEQ
    enc_t = time.perf_counter() - t
    print(f"ML encode(並列 teacher-forced): {enc_t*1e3:.0f} ms -> {done/1e6/enc_t:7.2f} MB/s")

    # --- B) decode-side throughput: strict serial ----------------------------
    ctx = data[: SEQ].copy()
    t = time.perf_counter()
    STEPS = 512
    for i in range(STEPS):
        x = mx.array(ctx[-SEQ:][None, :])
        lg = model(x)
        mx.eval(lg)  # real decode would append next byte
    dec_t = (time.perf_counter() - t) / STEPS
    print(f"ML decode(逐次): {dec_t*1e3:.2f} ms/byte -> {1/dec_t/1e6:7.4f} MB/s")

    print("\n== verdict:")
    print(f"   encode 並列化は可能だが CPU zlib より {z_t/(enc_t*1e3):.0f}x 遅い")
    print(f"   decode は逐次実行必須 → {n/1e6/(zd_t/1e3):.0f} MB/s の zlib に対し {1/dec_t/1e6:.4f} MB/s")
    print(f"   圧縮率は {'勝てる' if bpb/8 < len(zc)/n else '負ける'} (この小モデルでも). 速度と率はトレードオフ。")


if __name__ == "__main__":
    main()
