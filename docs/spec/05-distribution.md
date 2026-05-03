# 05. 配布

## 配布チャネル

| チャネル | URL |
|---------|-----|
| Homebrew Cask | [`hummer98/homebrew-aiview`](https://github.com/hummer98/homebrew-aiview) |
| GitHub Release | [`hummer98/AIview`](https://github.com/hummer98/AIview)（`.dmg` / `.zip` / `.sha256` を添付） |

## インストール

```bash
brew tap hummer98/aiview
brew install --cask aiview
```

Developer ID 署名 + Apple 公証済みのため、Gatekeeper 警告は出ない。

## 署名・公証

- 証明書: **Developer ID Application**（Apple Developer Program 加入が必要）
- 公証: `notarytool` + **App Store Connect API Key**（`.p8`）
- スクリプト: `scripts/notarize.sh`（手動実行・CI 双方で使用）
- Bundle ID: `com.ridgeroot.AIview`（task 020 で `com.aiview.*` から変更）

初回セットアップ手順は [`docs/signing-setup.md`](../signing-setup.md) を参照。日々のリリース手順は [`docs/release.md`](../release.md)。

## CI/CD

GitHub Actions のワークフロー:

| ファイル | トリガー | 内容 |
|---------|--------|------|
| `.github/workflows/release.yml` | `vX.Y.Z` タグ push | ビルド → 署名 → 公証 → `.dmg`/`.zip` を GitHub Release へ添付 |
| `.github/workflows/update-tap.yml` | release.yml の完了 | Cask formula を `homebrew-aiview` に PR / commit（SSH deploy key） |

ランナーは `macos-15` + Xcode 26.3。

## バージョン管理

- `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` は **git tag から同期**（task: release.yml 内で実行）
- リリースは `vX.Y.Z` タグの push が起点
- バージョン番号は [`CHANGELOG.md`](../../CHANGELOG.md) と同期（Keep a Changelog 形式）

## リリースワークフロー

1. `CHANGELOG.md` の `[Unreleased]` セクションを `[vX.Y.Z] - YYYY-MM-DD` に昇格
2. `git tag vX.Y.Z && git push origin vX.Y.Z`
3. `release.yml` が自動で署名・公証 → GitHub Release 作成
4. `update-tap.yml` が `homebrew-aiview` の Cask を更新
5. `brew upgrade --cask aiview` で配布完了

詳細は [`docs/release.md`](../release.md)。`/release` スラッシュコマンドも利用可能。

## アンインストール

```bash
brew uninstall --zap --cask aiview
```

`--zap` を付けると `~/Library/Preferences/com.ridgeroot.AIview.plist` 等のキャッシュも削除される。各画像フォルダ内の `.aiview/` は手動削除（ユーザーデータと同居しているため）。
