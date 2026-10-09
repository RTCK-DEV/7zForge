# 7zip for mac byRTCK

(開発リポジトリ名: 7zForge / アプリ名: 7zForge.app（表示名「7zip for mac byRTCK」）)

公式 7-Zip 26.04 (`Resources/7zz`, universal arm64/x86_64) を内蔵した macOS ネイティブ
アーカイブアプリ + Metal GPU 並列コーデック実験プラットフォーム。

SwiftUI / Swift 6.4 / Xcode-beta / Apple Silicon (M5 Pro) で開発・検証。

## 機能

- **圧縮**: ドラッグ&ドロップ、7z/zip、コーデック・レベル・辞書・スレッド数、
  AES 暗号化 (-mhe 含む)、プリセット (爆速/最高圧縮)、進捗 + キャンセル
- **解凍/一覧**: `l -slt` でテーブル表示 → 全量/選択解凍、上書き制御、パスワード
- **CPU ベンチ**: `7zz b` スレッドスイープ + Charts 可視化 (1〜15コア)
- **GPU 実験**: Metal 並列コーデック `.z7x` vs 7zz LZMA2-MT の正面比較、
  圧縮プロファイル選択 (爆速/バランス/最大/最適パース実験)

## ビルド & インストール

```bash
xcodegen generate
/Applications/Xcode-beta.app/Contents/Developer/usr/bin/xcodebuild \
    -project 7zForge.xcodeproj -scheme 7zForge -configuration Release \
    -derivedDataPath build/dd build
cp -R build/dd/Build/Products/Release/7zForge.app ~/Applications/
```

- `~/Applications/7zForge.app` — adhoc 署名済みスタンドアロン (macOS 15+、arm64)
- **ファイル連携**: .7z/.zip/.tar/.gz/.bz2/.xz/.zst/.cpio/.cab/.wim/.z7x を
  ダブルクリック → 解凍タブで一覧表示 (`.z7x` は GPU で直接解凍)
- `.z7x` は登録済み UTI `com.rtck.z7forge.z7x` (Owner)、他形式は Alternate なので
  既存アプリの関連付けは奪わない
- **Finder Quick Actions** (`NSServices`): 右クリック → Quick Actions に
  「7zForge で圧縮」「7zForge で解凍」が出る (アプリを一度起動すれば登録される。
  圧縮は選択ファイルを入力に追加、解凍はアーカイブを一覧/解凍タブで開く。
  「解凍」はアーカイブ拡張子のファイルのみに表示)
- **ショートカット**: ⌘O アーカイブを開く / ⌘1-4 タブ切替 / ⌘Return 圧縮・解凍実行。
  ウィンドウどこにでもドロップ可 (アーカイブ→解凍タブ、他→圧縮入力)
- **FinderSync 拡張** (`FinderExt.appex`、Google Drive 式のトップレベル項目):
  初回のみ システム設定 → 一般 → ログイン項目と機能拡張 → Finder 拡張 で
  `7zForge` を ON。以後 右クリックメニュー直下に「7zForge で圧縮/解凍」。
  本体アプリとは `z7forge://` URL スキームで連携
- 圧縮形式に `z7x` を選ぶと GPU プロファイル (爆速/バランス/最大) で
  実験フォーマット出力可 — 複数入力は単一ストリームに結合されるので注意

アイコンは `tools/make_icon.swift` で生成 (`/usr/bin/swift tools/make_icon.swift`
→ iconutil)。

## MCP サーバー

`7zForge --mcp` で stdio MCP サーバー化 (JSON-RPC 2.0 行単位)。ツール:

| tool | 機能 |
|---|---|
| `sevenz_compress` | inputs[]→archive。format/codec/level/threads/dict/solid/password |
| `sevenz_extract` | archive→dest (entries 選択・password・overwrite) |
| `sevenz_list` | エントリ一覧 JSON (path/size/packedSize/modified/isDirectory) |
| `z7x_compress` | GPU コーデック圧縮 (profile 0-3) |
| `z7x_decompress` | GPU コーデック解凍 (~1.3GB/s) |
| `sevenz_bench` | `7zz b` MIPS |

Devin CLI (user scope、登録済み): `~/.config/devin/mcp_config.json`

```json
{"mcpServers": {"z7forge": {
  "command": "~/Applications/7zForge.app/Contents/MacOS/7zForge",
  "args": ["--mcp"]}}}
```

Claude Desktop 等も同様に `command`/`args` を登録すればよい。

## ヘッドレス CLI

| コマンド | 動作 |
|---|---|
| `--selftest <file>` | 往復検証 (SHA256) + GPU/CPU ベンチ出力 |
| `--selftest --depth N --lazy N <file>` | プロファイル指定 (depth=99 は DP 実験) |
| `--z7x-write <in> <out.z7x>` | .z7x 書き出し (+ .dec に復号結果) |
| `--z7x-decode <in.z7x> <out>` | .z7x 復号 (堅牢性検証済み) |
| `--dump-tokens <in> <out>` | lit/code/off チャネルをダンプ (エントロピー解析用) |

Python 独立検証: `.venv/bin/python experiments/z7x2_verify.py <file.z7x> <orig>`
(far-match code 252・rep 253-255・3ch rANS 全対応、132MB でも sha match 確認済)

## Z7X3 フォーマット

```
magic "Z7X3" | version | blockSize(1MB) | segSize(16KB) | numBlocks | origSize
blockInfo[numBlocks] (compOffset/compSize/origSize/mode)
payload:
  mode0: 生データ (stored)
  mode1: lit|code|off 生チャネル (rANS 溢れ時フォールバック)
  mode2: rANS テーブル1536B | segCount | seg統計6配列 | rANS 3ストリーム/seg
code: 0-127=litrun, 128-251=明示マッチ(len 4-127), 252=far(u32 off), 253-255=rep1-3
offset: u24 (far は u32)、rep は 2B トークン
```

デコード: rANS 復号 → seg 毎 srcPos ポインタ生成 (lit=flag|位置) →
ポインタダブリングでコピーチェーン解決 (off=1 の 1MB チェーンも ~20 反復) →
gather。ブロック跨ぎマッチは絶対位置参照で自然に対応。

## 最終ベンチマーク (132MB バイナリ、最大プロファイル)

| | 圧縮率 | 圧縮 wall | kernel | 解凍 |
|---|---|---|---|---|
| **GPU Z7X3** | **2.97x** | 1138ms | 1070ms | **98ms ≈ 1.35GB/s** |
| 7zz LZMA2 mx1×15 | 3.7x | 445ms | — | 117ms |
| 7zz LZMA2 mx9 | 4.84x | 20s+ | — | — |
| zstd --ultra -22 | 6.2x | — | — | — |

**解凍はついに CPU 超え** (98ms vs 117ms)。圧縮率は LZMA2 に届かず — 残差は
ほぼ「rep 対応最適パース + 全履歴探索」由来で、GPU で実用速度を保ちながら
埋める手段は見つからなかった (後述棄却ログ)。

### プロファイル (圧縮率 vs 速度のダイアル)

| profile | big.bin | wall |
|---|---|---|
| 爆速 depth4 lazy0 | 2.61x | ~280ms |
| バランス depth8 lazy1 | 2.87x | ~430ms |
| 最大 depth24 lazy3 | 2.97x | ~1.1s |
| DP 実験 depth99 | 2.93x | ~3.2s |

### コーパス別

| corpus | size | GPU | 7zz mx1 |
|---|---|---|---|
| big.bin (繰返し少ないバイナリ) | 132MB | 2.97x | 3.7x |
| text | 268KB | 3.52x | ~5x |
| 実行ファイル混在 | 20MB | 3.37x | 3.85x |
| ソースコード | 804KB | 3.58x | 4.94x |
| syslog | 11.5MB | 14.10x | 16.89x |
| zeros | 3MB | 177x | — |
| random | 4MB | 1.00x stored | — |

---

# 実験ログ — 試したこと全部

「これ無理やろw」も含めて全て実測で判定。採用は効果順、棄却は理由付き。

## ✅ 採用した最適化 (累積 1.14x → 2.97x、解凍 759ms → 98ms)

### 圧縮率

| # | 変更 | 効果 |
|---|---|---|
| 1 | LZSS ハッシュマッチング基礎 (4B/8B 二段 zstd-dfast 風) | v1 1.14x |
| 2 | **3ch 分割 rANS** (lit/code/off に独立 order-0 モデル) | 2.09→2.19x |
| 3 | **ハッシュ幅 17→19→21bit** (バケット飽和を解消) | →2.46x |
| 4 | 24-deep 4B チェーン + 8-deep 8B チェーン | →2.90x 水準 |
| 5 | **lazy lookahead** (i+1/i+2 先読み、l≤8 のみ発動) | +7% |
| 6 | **rep1-3 直接 probe** (LRU 位置をハッシュ不使用で検証) | +3% |
| 7 | **backward extension** (マッチ開始を前に延ばし lit-run を食う) | →2.94x |
| 8 | far-match code 252 (u32 off、ブロック跨ぎ全域窓) + コストペナルティ | +0.5% |
| 9 | seg 8→16KB (rep LRU 持続・並列度の均衡点) | →2.97x |
| 10 | good-enough 早期終了 (l≥32 で候補打切り) | zeros 高速化 |

### 速度

| # | 変更 | 効果 |
|---|---|---|
| 1 | **解凍 srcPos ポインタジャンプ** (ACEAPEX 論文の方式) | 759→186ms |
| 2 | GPU memset で heads 初期化 (CPU memset 廃止) | wall-kernel gap ~70ms |
| 3 | rep ファストパス (rep≥16 で probe 全スキップ) | zeros 83→49ms |
| 4 | 入出力 bytesNoCopy (mmap 入力 + noCopy 出力) | decomp 120→98ms |
| 5 | stored-only ブロック CPU memcpy パス | rand decomp 56→0.4ms |
| 6 | セグメント並列 rANS (各 seg が独立エンコード) | 設計基盤 |

## ❌ 棄却したもの (測定 or 推定で否定 — 再実験不要)

| 実験 | 結果 | 判定理由 |
|---|---|---|
| **MLX/ML 圧縮** | encode 0.45MB/s (160x遅)、decode 0.001MB/s (~100万倍遅) | byte 逐次依存は演算器を変えても解消しない。構造的限界 |
| **matchLen8** (8B XOR+ctz 比較) | kernel +50ms 悪化 | avg 12B の短マッチでは byte loop が速い |
| **DP 最適パース** (depth=99) | text +4% だが big -5%、depth24 でも 2.93x@3.2s | rep 非対応コストモデルが敗因。rep-aware DP は状態爆発 |
| **スパース far-table** (8位置に1回挿入) | +0.07% のみ +77ms | 遠距離マッチを見つけても長さ ~9B で得なし |
| **マッチ内部のハッシュ挿入** | 効果ゼロ +17ms | 貪欲スキップと実質同等 |
| **varint オフセット** | — | off の 54% が >2MB で分布解析の時点で悪化確定 |
| **オフセット差分符号化** | 31.8MB vs 28.5MB で悪化 | 連続マッチのオフセットは無相関 |
| **off チャネル更分割** | 残り ~1.3MB | far 4byte目以外は既に均一分布 |
| **order-1 literal** | +5%/1MB | 128KB/block ヘッダに不釣合 |
| **order-1 code** | +1.75MB (3.01x) | 64K コンテキストヘッダに不釣合 |
| **マッチ長延長 (>127)** | — | cap 到達 0.0% (繰り返しは本質的に短い) |
| **rep len-3** | 推定 +0.1% | フォーマット変更に不釣合 |
| **blockSize 4MB** | 2.95x 微悪化 | 共有モデルの希釈 |
| **seg 32KB** | 2.84x + kernel 2倍 | GPU 占有低下 |
| **chain 32-deep** | +0.02x に +155ms | 収穫逓減 |

## 🔬 副次的発見

- **公式 7-Zip に Zstd 圧縮は存在しない** (`.zst` 解凍のみ。mcmilk フォークのみ
  圧縮対応) — 爆速プリセットは LZMA2 mx1+non-solid が実在の最速
- **LZMA2 mx5+ は単一ファイルで MT がほぼ効かない** (M5 Pro で ~1.3コア相当)
- **rANS cap 溢れ**: 全 lit seg で rANS は ~1.15x 膨張 → cap+クランプ+mode1
  フォールバックが必須 (buffer 破壊バグの根本原因)
- **逐次性の正体はパース** (文献実測 64-72%) — self-overlap コピーはポインタ
  ダブリングで完全並列化できる
- **小ファイルは CPU 完勝**: seg 内走査の逐次性で GPU kernel に ~300ms/seg
  floor があり、800KB では GPU 318ms vs CPU 33ms。大容量専用

## コード構成

```
Sources/
  SevenZApp.swift    headless モード振り分け
  SelfTest.swift     --selftest/--z7x-*/--dump-tokens
  GPUCodec.swift     Z7X3 シリアライズ + Metal ディスパッチ + 堅牢パース
  Shaders.metal      compress/hist/rANS/parse/chase/materialize/seq カーネル
  GPUBenchView.swift GPU vs CPU 比較 UI (プロファイル付)
  SevenZip.swift     7zz プロセスラッパー
  CompressView/ExtractView/BenchmarkView/CommonUI/ContentView
experiments/
  z7x2_verify.py     Python 独立検証器 (Z7X3 全フォーマット対応)
  token_entropy.py   チャネル別エントロピー解析
  rans_ref.py/rans_grid.py  rANS スキーム検証・パラメータ探索
  mlx_probe.py       MLX 圧縮実測 (却下根拠)
```

## ライセンス

7-Zip は LGPL (Resources/License-7zip.txt 参照)。
