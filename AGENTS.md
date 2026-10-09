# 7zForge — エージェント向けメモ

公式 7-Zip (`Resources/7zz`、26.04 universal) を内蔵した macOS SwiftUI アプリ +
Metal GPU 並列コーデック実験 (Z7X 独自フォーマット)。

## ビルド / テスト

```bash
xcodegen generate   # project.yml 変更時のみ
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
    -project 7zForge.xcodeproj -scheme 7zForge -configuration Release \
    -derivedDataPath build/dd build
BIN=build/dd/Build/Products/Release/7zForge.app/Contents/MacOS/7zForge
```

- ヘッドレス自己検証: `$BIN --selftest <file>` （`--depth N --lazy N` でプロファイル指定、
  `--depth 99` は DP 実験モード）
- Z7X ファイル書き出し/復号: `$BIN --z7x-write <in> <out.z7x>` / `--z7x-decode <in.z7x> <out>`
- Python 独立検証: `.venv/bin/python experiments/z7x2_verify.py <file.z7x> <orig>`
- 環境: Apple Silicon (M5 Pro 15スレッド)、Xcode-beta、Swift 6.4

## Z7X3 フォーマット (現行)

`Z7X3` マジック、1MB ブロック × 16KB セグメント、3 チャネル
(literal | code | offset) 各ブロック共有 order-0 モデル rANS。
code: 0-127 リテラルラン、128-251 明示マッチ、252 far(u32 off)、253-255 rep1-3。
ブロックモード: 0=stored, 1=raw, 2=rANS (溢れ時は 1 にフォールバック)。
デコード: rANS→srcPos ポインタ生成→ポインタダブリングでコピーチェーン解決→gather。
ブロック跨ぎマッチ可 (絶対位置参照)。

## 実測済み実験ログ (132MB バイナリ基準、全て verify OK 確認済)

### 採用した改善 (累積 1.14x → 2.97x)

| 変更 | 効果 |
|---|---|
| 3ch 分割 rANS | +5% |
| ハッシュ 17→21bit | +9% |
| lazy lookahead (i+1,i+2、l≤8 のみ) | +7% |
| rep1-3 直接 probe (ハッシュ不使用) | +3% |
| backward extension | +4% |
| rep ファストパス (rep≥16 で probe スキップ) | zeros 2x 高速化 |
| seg 8→16KB | +4% (32KB は悪化) |
| chain depth 24 + heads8 8-deep | +3% |
| far-match code 252 + コストペナルティ | +0.5% |
| GPU memset (heads 初期化) | wall-kernel gap 70ms 化 |
| 解凍: srcPos ポインタジャンプ | 759→120ms (6x) |
| 入出力 bytesNoCopy (mmap 入力 + noCopy 出力) | decomp 120→98ms (~1.35GB/s) |
| stored-only ブロックは CPU memcpy パス | rand decomp 56→0.4ms |

### 棄却 (測定して否定 — 再実験不要)

- matchLen8 (8B 単位比較): kernel +50ms 悪化 — avg 12B マッチには byte loop が速い
- match 内部位置のハッシュ挿入: 効果ゼロ +17ms
- スパース far-table: +0.07% のみ +77ms
- varint オフセット / オフセット差分符号化: 分布解析で悪化確定 (off の 54% >2MB)
- off チャネル更分割 / order-1 literal: +1.3MB / +5% に実装コスト不釣合
- DP 最適パース (depth=99): text +4% だが big -5%、rep 非対応コストモデルが敗因。
  depth24 DP でも 2.93x@3.2s < greedy 2.97x@1.1s
- 32KB seg / chain 32-deep: 収穫逓減で悪化
- MLX/ML 圧縮: encode 0.45MB/s (160x遅), decode 0.001MB/s (~100万倍遅) — 構造的限界

### プロファイル (`--depth`/`--lazy`, UI の爆速/バランス/最大)

| profile | big.bin | wall |
|---|---|---|
| 4/0 爆速 | 2.61x | ~280ms |
| 8/1 バランス | 2.87x | ~430ms |
| 24/3 最大 | 2.97x | ~1.1s |
| 99 DP実験 | 2.93x | ~3.2s |

### 重要な限界

- **seg 内走査は逐次**: kernel に ~300ms/seg の floor。小ファイル (<数MB) では
  GPU が CPU に速度でも負ける → 大きいファイル専用
- **解凍は CPU と互角** (big: 120ms ≈ 1.1GB/s vs 7zz 117ms)
- order-1 code モデル: +1.75MB (2.97→3.01x) のみ、64K コンテキストヘッダに不釣合で棄却
- rep len-3 マッチ: 推定 +0.1% のみ — フォーマット変更に不釣合で棄却
- blockSize 4MB: モデル希釈で 2.95x に微悪化 → 1MB 維持
- decompress() はヘッダ/ストリーム境界を検証済み — 60-case fuzz で crash ゼロ
  (payload 内 1byte 破損は CRC なしのため検出不可、仕様上許容)
- LZMA2 mx1 (3.7x) との残差はほぼ最適パース+全履歴探索由来 — rep-aware DP は
  状態爆発で実用圏外と判断

## コーパス別実績 (最大プロファイル)

| corpus | size | ratio | vs 7zz mx1 |
|---|---|---|---|
| big.bin (binary) | 132MB | 2.97x | 3.7x |
| text | 268KB | 3.52x | ~5x |
| zeros | 3MB | 177x | - |
| 実行ファイル混在 | 20MB | 3.37x | 3.85x |
| ソースコード | 804KB | 3.58x | 4.94x |
| syslog | 11.5MB | 14.10x | 16.89x |
| random | - | 1.00x (stored) | - |
