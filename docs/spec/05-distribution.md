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

## 利用計測（匿名テレメトリ）

配布後の利用状況を把握するため、アプリ起動時に**匿名の利用 ping** を日次で 1 回だけ送信する。設計判断は ADR [`002-anonymous-usage-telemetry`](../adr/002-anonymous-usage-telemetry.html)。

- **opt-out（既定 ON）**: 設定「表示 > プライバシー > 匿名の利用統計を送信する」で停止できる。OFF の間は計測目的の通信を一切行わない。
- **送信内容（PII 無し）**: 匿名 install UUID / アプリ版 / macOS 版 / CPU アーキ / ロケール。国コードはサーバ側で CF ヘッダから付与（IP は保存しない）。ファイル・画像・個人情報は送らない。
- **実装**: クライアントは `TelemetryService`（`Sources/Data/`）。起動時に `UserDefaults` の最終送信日(UTC)で日次デバウンスし、fire-and-forget で GET。
- **サーバ**: 自前ホストの Cloudflare Worker + D1（`cloudflare/aiview-metrics/`）。install 単位 1 行を upsert し、`GET /stats?key=STATS_KEY` が集計 JSON（total / new_today / dau,wau,mau / 版・OS・アーキ・国分布）を返す。デプロイ・集計手順は同ディレクトリの README を参照。

### 集計の確認

```bash
curl -s "https://aiview-metrics.rr-yamamoto.workers.dev/stats?key=$STATS_KEY" | python3 -m json.tool
```

`STATS_KEY` は Worker の secret（ローカルは `cloudflare/aiview-metrics/.stats-key`、gitignore）。
