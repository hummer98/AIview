---
description: docs/spec/ と README / CHANGELOG / CLAUDE.md を実装の現状に同期する
---

# /sync-docs — ドキュメント同期

`docs/spec/`, `README.md`, `README-ja.md`, `CHANGELOG.md`, `CLAUDE.md` を
git log と現実装に照らし合わせて差分検出・更新するコマンド。

## 役割

実装が先行してドキュメントが追いついていないケースを検出し、必要箇所を更新する。
判断材料は `git log` と、存在すれば `.team/task-state.json` の closed タスク。

対象ファイル:

| ファイル | 内容 |
|---------|------|
| `docs/spec/*.md` | 統合仕様書（実装の「何を・なぜ」） |
| `README.md` / `README-ja.md` | ユーザー向け入門ガイド（英日対訳） |
| `CHANGELOG.md` | 次リリースに含める変更履歴 |
| `CLAUDE.md` | 設計思想・規約 |

## 引数

| モード | 動作 |
|--------|------|
| `--dry-run` | 差分レポートのみ出力。ファイルは変更しない |
| （デフォルト） | 差分を提示し、確認後に更新 |
| `--auto` | 確認なしで自動更新 |

## 同期手順

### 1. docs/spec/ の最終更新時点を確認

```bash
git log -1 --format="%H %ai %s" -- docs/spec/ 2>/dev/null
```

→ `<base_hash>` と `<last_updated>` を記録する。

`docs/spec/` がまだ無ければ **bootstrap モード** に切り替え、章立て案をユーザーに確認してから作成する（後述）。

### 2. それ以降の実装変更を収集

```bash
# 実装ファイルに絞る
git log --oneline <base_hash>..HEAD -- AIview/ AIviewTests/ AIviewUITests/ AIview.xcodeproj/ scripts/
```

各コミットの内容（feat / fix / refactor / docs）と影響範囲を把握する。
`git show --stat <hash>` で変更ファイルを確認。

### 3. closed タスクで補完（あれば）

```bash
test -f .team/task-state.json && python3 -c "
import json
data = json.load(open('.team/task-state.json'))
for tid, info in data.items():
    if info.get('status') == 'closed':
        print(tid, info.get('title',''))
"
```

変更内容が曖昧なコミットは、対応するタスクファイル（`.team/tasks/<id>-*.md`）を読んで補完する。

### 4. 対象ドキュメントと照合

各ファイルを読み、収集した変更内容と差異を検出する。

| ファイル | 重点チェック項目 |
|---------|------------|
| `docs/spec/00-overview.md` | プロジェクト概要・対象ユーザー |
| `docs/spec/01-architecture.md` | レイヤ構成（App / Domain / Data / Presentation）・依存関係 |
| `docs/spec/02-features.md` | キーボード操作・お気に入り・スライドショー・プライバシーモード |
| `docs/spec/03-thumbnail-cache.md` | キャッシュ保存先・mtime 検証戦略・除外事項 |
| `docs/spec/04-prefetch.md` | プリフェッチ戦略・優先度キュー・LRU キャッシュ |
| `README.md` / `README-ja.md` | キーボードショートカット表・対応形式・インストール手順 |
| `CHANGELOG.md` | 未リリース変更が記録されているか（Keep a Changelog 形式） |
| `CLAUDE.md` | 設計思想（キャッシュ戦略等）の変更 |

英日 README はセクション構造・見出し・記述順を揃える（対訳関係を維持）。

### 5. 差分レポート出力

```
## ドキュメント同期レポート

最終 docs/spec 更新: <last_updated>
対象コミット: N件

### 更新が必要なファイル

#### docs/spec/02-features.md
- ⌘↑/⌘↓ ショートカット追加（commit e9b422e, T018）

#### README.md / README-ja.md
- キーボードショートカット表に ⌘↑/⌘↓ を追記（英日両方）

#### CHANGELOG.md
- [Unreleased] セクションに ⌘↑/⌘↓ ナビゲーション追加を記載

### 変更不要なファイル
- 00-overview.md — 変更なし
- 01-architecture.md — 変更なし
- CLAUDE.md — 設計思想変更なし

### 要確認
- bundle-id 変更（commit 329a3a7）— ユーザー向け記述への影響を判断
```

### 6. 更新実行（デフォルト・--auto モード）

差分レポートで提示した変更を各ファイルに反映する。
`--dry-run` の場合はここでスキップし終了。

## bootstrap モード（docs/spec/ が無い場合）

初回実行時は章立てを提案し、ユーザー確認後に作成する:

1. `git log` 全体を解析して機能・設計判断を抽出
2. 章立て案（00-overview / 01-architecture / 02-features / 03-thumbnail-cache / 04-prefetch 等）を提示
3. ユーザー承認後、各 spec ファイルを生成
4. CLAUDE.md に「仕様書の所在」セクションを追記

## 注意事項

- `docs/spec/` は「実装と同期された仕様書」。内部実装詳細・進行中タスクは書かない
- `README.md` / `README-ja.md` は「ユーザーが最初に読むドキュメント」。開発者向け内部仕様は入れない
- 削除されたファイル・機能の記述は除去する
- 既存の文体・構造を維持する（大幅なリフォーマットはしない）
- 不明な変更は推測で書かず、レポートに「要確認」として記載する
- CHANGELOG は `[Unreleased]` セクションに追記。リリース時に `/release` がバージョン番号付きセクションに昇格させる
