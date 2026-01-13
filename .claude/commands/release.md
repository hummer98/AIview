# Release - AIview新バージョンリリース

このコマンドは、AIviewの新バージョンをリリースするための一連の手順を自動化します。

## 実行手順

以下の順序で実行してください：

### 1. 前提条件チェック

まず、未コミットの変更があるか確認します：

```bash
git status --porcelain
```

**未コミットの変更がある場合:**
- ユーザーに確認してください
- 必要であれば `/commit` コマンドを実行してコミットを作成
- コミット後、このコマンドを再実行

### 2. バージョン決定

現在のバージョンを確認し、次のバージョンを決定します：

```bash
# 現在のバージョン確認（Xcodeプロジェクト）
grep -E 'MARKETING_VERSION' AIview.xcodeproj/project.pbxproj | head -1

# 最近のコミットを確認してバージョンタイプを判定
git log --oneline -10
```

**バージョンタイプの判定基準:**
- **patch (1.1.0 → 1.1.1)**: バグ修正のみ（`fix:`, `docs:` など）
- **minor (1.1.0 → 1.2.0)**: 新機能追加（`feat:` など）
- **major (1.1.0 → 2.0.0)**: 破壊的変更（`BREAKING CHANGE`）

ユーザーに次のバージョンを提案し、確認を取ってください。

### 3. Xcodeプロジェクトのバージョン更新

決定したバージョンで `AIview.xcodeproj/project.pbxproj` の `MARKETING_VERSION` を更新します。

```bash
# 全てのMARKETING_VERSIONを一括更新
sed -i '' 's/MARKETING_VERSION = [0-9.]*;/MARKETING_VERSION = X.Y.Z;/g' AIview.xcodeproj/project.pbxproj
```

### 4. CHANGELOG.md更新

最新のコミットログから変更内容を抽出し、CHANGELOG.mdに追記します：

```bash
# 前回のリリースタグから現在までのコミットを取得
# 初回リリースの場合は全コミットを取得
git log --oneline
```

CHANGELOG.mdのフォーマット:
```markdown
# Changelog

## [X.Y.Z] - YYYY-MM-DD

### Added
- 新機能の説明

### Fixed
- バグ修正の説明

### Changed
- 変更内容の説明
```

**注意**: CHANGELOG.mdが存在しない場合は新規作成してください。

### 5. ビルド＆テスト

```bash
# テスト実行
task test:unit

# リリースビルド
task build:release
```

**テストが失敗した場合:**
- リリースを中断
- 失敗原因をユーザーに報告

### 6. アーカイブ作成

```bash
task archive
```

### 7. 変更のコミット＆プッシュ

```bash
git add AIview.xcodeproj/project.pbxproj CHANGELOG.md
git commit -m "chore: bump version to vX.Y.Z

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
git push origin master
```

**注意**: リモートリポジトリが設定されていない場合は、まずGitHubリポジトリを作成してリモートを追加するようユーザーに案内してください。

### 8. Gitタグの作成＆プッシュ

バージョンタグを作成してリモートにプッシュ：

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
```

### 9. GitHubリリース作成

リリースノートをCHANGELOGから抽出し、GitHubリリースを作成：

```bash
gh release create vX.Y.Z \
  --title "AIview vX.Y.Z" \
  --notes "[CHANGELOGから抽出したリリースノート]"
```

### 10. dmgファイルの作成と添付（オプション）

dmgファイルを作成してリリースに添付する場合：

```bash
# アプリをdmgにパッケージング
hdiutil create -volname "AIview" -srcfolder "build/Build/Products/Release/AIview.app" -ov -format UDZO "build/AIview-X.Y.Z.dmg"

# GitHubリリースに添付
gh release upload vX.Y.Z "build/AIview-X.Y.Z.dmg"
```

### 11. Applicationsフォルダへデプロイ（ローカル開発用）

```bash
rm -rf "/Applications/AIview.app"
cp -R "build/Build/Products/Release/AIview.app" /Applications/
```

### 12. 完了報告

ユーザーに以下を報告：
- リリースバージョン
- リリースページURL（GitHubリリースが作成された場合）
- 主な変更内容のサマリー

## 注意事項

- このコマンドはAIviewプロジェクト専用です
- 必ずmasterブランチで実行してください
- リリース作成前にテストが通っていることを確認してください
- バージョン番号は手動で確認・承認を得てから進めてください
- リモートリポジトリが未設定の場合、push関連の手順はスキップされます

## エラー処理

各ステップでエラーが発生した場合:
1. エラー内容をユーザーに報告
2. 修正方法を提案
3. 必要に応じてロールバック手順を案内

## 初回リリース時の追加手順

GitHubリポジトリが未作成の場合：

1. GitHubでリポジトリを作成
2. リモートを追加：
   ```bash
   git remote add origin https://github.com/USERNAME/AIview.git
   ```
3. 初回プッシュ：
   ```bash
   git push -u origin master
   ```
