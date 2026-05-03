# Project

## 仕様書の所在

実装の「何を・なぜ」を確認したいときは [`docs/spec/`](docs/spec/) を起点にする:

| ファイル | 内容 |
|---------|------|
| [`00-overview.md`](docs/spec/00-overview.md) | プロジェクト概要・対象ユーザー・価値提案 |
| [`01-architecture.md`](docs/spec/01-architecture.md) | レイヤ構成（App / Domain / Data / Presentation）、データフロー、並行性 |
| [`02-features.md`](docs/spec/02-features.md) | 機能仕様、キーボードショートカット表 |
| [`03-performance-and-caching.md`](docs/spec/03-performance-and-caching.md) | プリフェッチ戦略、LRU メモリキャッシュ、メトリクス |
| [`04-thumbnail-cache.md`](docs/spec/04-thumbnail-cache.md) | サムネイル `.aiview/` 設計、mtime 検証、設計思想 |
| [`05-distribution.md`](docs/spec/05-distribution.md) | 署名・公証・Homebrew Cask・CI/CD |

ユーザー向け入門は [`README.md`](README.md) / [`README-ja.md`](README-ja.md)、変更履歴は [`CHANGELOG.md`](CHANGELOG.md)。

## ドキュメント更新ポリシー

実装変更（コード追加・修正・削除）を行うときは、完了前に以下のいずれかへの反映を確認すること:

| ドキュメント | トリガー |
|------------|--------|
| `docs/spec/*.md` | 機能仕様・アーキテクチャ・データ保存形式の変更 |
| `README.md` / `README-ja.md` | ユーザー可視機能の追加・変更（ショートカット、対応形式、コマンド） |
| `CHANGELOG.md` | 次リリースに含めるすべての変更 |
| `CLAUDE.md` | 設計思想・規約の決定 |

`/sync-docs` で git log と既存ドキュメントの差分レポートを取得できる。英日 README は対訳関係を維持（セクション構造・見出し・記述順を揃える）。

## 設計思想

### サムネイルキャッシュの保存先

**原則: キャッシュはデータと同じ場所に置く。**

- サムネイルは各フォルダ直下の `.aiview/` サブフォルダ（隠しフォルダ）に保存する
- ファイル名は元ファイル名 + `.jpg`（例: `sunset.heic` → `.aiview/sunset.heic.jpg`）
- mtime 検証はキャッシュファイルと元ファイルの属性比較で行う（ファイル名への埋め込みはしない）
- サムネイルサイズは 80×80 固定、複数サイズは持たない
- hash・identity key・シャーディング・全体 LRU は不要

**この原則の理由（中央集約化を採用しない理由）:**
- NAS 上の画像を開いたとき、ローカルマシンに他ロケーションのキャッシュが溜まり続けるのは望ましくない
- 別マシンから同じ NAS を開いたときにキャッシュが共有される
- 外付けドライブを持ち出せばキャッシュも一緒に付いてくる
- フォルダ削除時にキャッシュも自然に消える（孤立しない）
- ユーザーフォルダに `.aiview/` が残るのは仕様として許容する（高速化を優先）

**書き込めないメディア（read-only マウント等）のフォールバックは行わない。** キャッシュを作れない場合は都度生成する。

詳細は [`docs/spec/04-thumbnail-cache.md`](docs/spec/04-thumbnail-cache.md)。
