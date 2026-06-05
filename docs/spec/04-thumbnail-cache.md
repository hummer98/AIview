# 04. サムネイルキャッシュ設計

## 大原則

> **キャッシュはデータと同じ場所に置く。**

サムネイルは各フォルダ直下の `.aiview/` サブフォルダ（隠しフォルダ）に保存する。

```
your-image-folder/
├── sunset.heic
├── draft01.png
└── .aiview/
    ├── favorites.json    ← FavoritesStore が共有（お気に入り + 前回の表示位置の v2 形式）
    ├── sunset.heic.jpg   ← サムネイル本体
    └── draft01.png.jpg
```

ファイル名は **元ファイル名 + `.jpg`**。サイズは **80×80 固定**。

## 中央集約しない理由

過去に `~/Library/Application Support/AIview/DiskCache/` への中央集約を試みたが、以下の理由で per-folder 方式に回帰した（task 019）:

| 場面 | 中央集約の問題 | per-folder の挙動 |
|------|------|---------------------|
| NAS 上の画像を別マシンから開く | キャッシュが共有されない | NAS 上の `.aiview/` で共有 |
| 外付けドライブを持ち出す | キャッシュが取り残される | ドライブと一緒に付いてくる |
| フォルダを削除 | 中央キャッシュが孤児として残る | 一緒に消える |
| 異なるロケーションの画像を開く | ローカル容量を消費し続ける | 各フォルダ内に分散 |

**ユーザーフォルダに `.aiview/` が残るのは仕様として許容**。高速化と運用の素直さを優先。

## mtime 検証戦略

ファイル名にハッシュや identity key を埋め込まず、**mtime 比較**で hit/miss を判定する。

### 1 秒許容差

```swift
let tolerance: TimeInterval = 1.0
abs(cacheMtime.timeIntervalSince(modificationDate)) < tolerance
```

**等値比較ではなく 1 秒許容差にした理由:**

- SMB/NTFS マウントは mtime を 100 ns 単位に丸める。APFS の ns 精度と等値比較すると毎回 stale になる
- `Date(Double)` の浮動小数点精度誤差も同時に吸収できる
- 同一秒内に「ファイル更新 → キャッシュ生成 → さらに更新」が起きる現実的な可能性はほぼない
- `cp -p` 等の mtime-preserving copy で stale を見逃す既知の妥協と整合的

### 書き込み側の精度

`storeThumbnail()` は `setResourceValues(.contentModificationDate)` を使い ns 精度で mtime をコピーする（`setAttributes(.modificationDate:)` は秒精度に丸まるため使わない）。

許容差は **比較側でのみ吸収**。書き込み側で精度を落とす意味はない。

## やらないこと（明確な非対応）

| 項目 | 理由 |
|------|------|
| ファイル名へのハッシュ埋め込み | mtime 比較で十分。デバッグ性を下げない |
| identity key（inode 等） | 過去の試みで複雑性に見合う利得がなかった |
| シャーディングディレクトリ | フォルダ単位なので不要 |
| 全体 LRU / index plist | フォルダ単位の局所性を信頼する |
| 複数サイズ | 80×80 固定 |
| 書き込み不可メディアのフォールバック | 都度生成する。代替パスを持たない |

## `.aiview/` の安全性

- `FolderScanner` の `skipsHiddenFiles` で自動スキップされ、画像リストに `.aiview/*.jpg` は混じらない
- `favorites.json` を `FavoritesStore` が共有利用するため、ディレクトリ単位の削除はしない（ファイル単位のみ）
- `mtime-preserving copy`（`cp -p`、`rsync -a`、Photos export）で内容が変わった場合は stale を返す既知の挙動（content hash を持たないため）
- 画像ファイルだけ削除されると `.aiview/<name>.jpg` は孤児として残る。全体 LRU を廃した以上これは受容（フォルダごと削除されたときのみ自然消滅）

## 旧中央キャッシュの自動パージ

task 019 で per-folder 方式に回帰したため、起動時に 1 回だけ `~/Library/Application Support/AIview/DiskCache/` を削除する（`AIviewApp.purgeLegacyCentralCache`）。失敗は warning で握り潰す。

## 関連実装

- `Sources/Data/DiskCacheStore.swift` — actor、本ドキュメントの仕様を実装
- `Sources/Domain/ThumbnailCacheManager.swift` — メモリ層 + DiskCacheStore 連携
