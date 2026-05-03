# 00. プロジェクト概要

## ミッション

AIview は **大量画像コレクション（1,000〜2,000 枚規模）の高速ブラウジング** に特化した macOS 向け画像ビューア。応答性を最優先し、フォルダを開いた瞬間に最初の画像を表示し、矢印キー連打でも UI をブロックしないことを目標とする。

## 中核価値

| 価値 | 実現方法 |
|------|----------|
| **即時表示** | フォルダ走査の完了を待たず、最初に見つかった画像を即座に表示 |
| **ゼロレイテンシ操作** | 進行方向を予測したプリフェッチで次/前の画像を先回り |
| **キーボード駆動** | 矢印キー・数字キー・スペースで完結する選別ワークフロー |
| **AI 生成画像対応** | PNG tEXt / XMP から Stable Diffusion プロンプトを抽出 |

## 想定ユースケース

- AI 生成画像（Stable Diffusion / Midjourney 等）の大量バッチを素早くレビュー・選別
- 一括生成セッションから不要な画像を高速削除（Trash へ移動）
- 生成パラメータ（プロンプト・ネガティブプロンプト・Steps 等）の確認
- 写真コレクションを最小 UI で閲覧

## 対応形式

JPEG (.jpg/.jpeg)、PNG (.png)、HEIC (.heic)、WebP (.webp)、GIF (.gif)

## 動作要件

- macOS 14.0 (Sonoma) 以降
- Apple Silicon または Intel Mac（universal binary、現状は Apple Silicon で主に検証）

## 配布

- Homebrew Cask: `brew tap hummer98/aiview && brew install --cask aiview`
- Developer ID 署名 + Apple 公証済み（Gatekeeper 警告なし）
- 詳細は [`05-distribution.md`](05-distribution.md)

## 設計の起点となる原則

1. **応答性 > 機能性** — 機能を増やすときは応答性を損なわないことを必ず確認
2. **データと一緒にキャッシュを置く** — `.aiview/` をフォルダ直下に作る（中央集約しない）。詳細は [`04-thumbnail-cache.md`](04-thumbnail-cache.md)
3. **書き込めない場合のフォールバックは作らない** — read-only メディアでは都度生成
4. **ユーザーフォルダに `.aiview/` が残るのを許容** — 高速化を優先
