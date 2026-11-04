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
| `.github/workflows/ci.yml` | 全branch push / pull request / reusable call | Xcode 26.6のbuild/static gate後、unit / E2E / UI / TSanを独立matrix jobで実行。全job成功を最終quality jobで集約 |
| `.github/workflows/release.yml` | `vX.Y.Z` タグ push | ビルド → 署名 → 公証 → `.dmg`/`.zip` を GitHub Release へ添付 |
| `.github/workflows/update-tap.yml` | release.yml の完了 | Cask formula を `homebrew-aiview` に PR / commit（SSH deploy key） |

quality / release / release dry-runのランナーは`macos-26`（arm64）+ Xcode 26.6。GitHub公式の[macOS 26 arm64 image manifest](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md#macos-26)は2026-08-11確認時点でmacOS 26.5.2 (25F84)、Xcode 26.6 (17F113)を掲載している。preflightと4 runtime jobは`sw_vers`、`ImageOS`、`ImageVersion`を記録し、macOS 26.5未満を実行前に拒否する。Xcode 26.6の`xcresulttool get test-results` schema version 0.1.0を明示し、各bundleでsummary `Passed`、failure 0、skip 0、source上の最低件数、exact test-node名を検証する。

| runtime job | 選択範囲 | source最低件数 | timeout | artifact |
|-------------|----------|---------------:|--------:|----------|
| Unit | unhosted `AIview-UnitTests` schemeの`AIviewTests`（`FavoritesE2ETests`を除外） | 359 | 60分 | `AIviewTests.xcresult` |
| Favorites E2E | unhosted `AIview-UnitTests` schemeの`AIviewTests/FavoritesE2ETests` | 26 | 45分 | `FavoritesE2ETests.xcresult` |
| XCUIApplication UI | generated `.xctestrun`のscheme skipを解除して`AIviewUITests/ScrollPerformanceUITests` | 6 | 60分 | `AIviewUITests.xcresult` |
| TSan race/cancel | unhosted `AIview-UnitTests` schemeの`FolderScannerTests` + `ImageBrowserSessionTests`、`ImageLoaderContentionTests`、`BrowserWindowSessionTests`、`FavoritesMetadataPrivacyTests`、`ThumbnailWarmerTests` | 47 | 75分 | `AIviewTSan.xcresult` |

matrixは`fail-fast: false`のため、1 suiteが失敗しても残りのsuiteは実行される。4 artifactは成功・失敗を問わず収集を試みて14日保持し、欠落自体もjob failureとする。最後の`quality` jobはpreflightと全matrix結果がすべて`success`の場合だけ成功する。tag release / dry-runは同一commitのこの集約結果へ明示的に依存する。

unit / E2E / TSanはshared `AIview-UnitTests.xcscheme`を使う。これはTestActionをDebug、launcherをPosixSpawn、testableをunhosted `AIviewTests`だけに限定し、app hostのLaunchServices経路を通さない。`task test:scheme:check`はこのXML契約とDebug targetの`TEST_HOST` / `BUNDLE_LOADER`欠落をpreflightと各unit系runtime jobで検査する。XCUIApplication UIだけはapp起動が必要なため既存`AIview` schemeに残す。

TSanのsource最低件数は上記5ファイルにある全47 test methodを数える。`FolderScannerTests.swift`には`FolderScannerTests`と`ImageBrowserSessionTests`の2 XCTestCaseがあるため、両classを`-only-testing`とexact node gateへ明示し、file countだけ増えて実行scopeが追従しない場合は失敗させる。

schemeの通常Test actionは6件のperformance UI suiteをskipする設定を持つため、`-only-testing`だけではCI evidenceにならない。`task test:ui`は`build-for-testing`で作成した`.xctestrun`をBuild/Products内に複製し、構造をparseして一意の`AIviewUITests` targetを特定、そのentryの`SkipTestIdentifiers`だけを除去して`test-without-building`を実行する。生成物にskipが残る場合はruntime前に失敗する。source上に`XCTSkip`はなく、全runtime jobでskip 0をrelease invariantとする。

2026-08-11時点ではlocal macOS 26.4.1 (25E253) + Xcode 26.6でhosted test/UIのLaunchServices invalid-PID callbackに起因するlauncher assertionが発生した。unhosted unit schemeのfocused 13件に加え、TSan focused suiteは47/47（failure/skip 0、6 suiteのsource/result差分0、sanitizer報告0）で成功した。ただしOS 26.5未満のlocal diagnosticでありfull quality evidenceではない。このためmacOS 26.5を下限にしたが、clean GitHub runnerは未実行である。workflow定義、generated xctestrunのskip解除確認、local runtime成功だけではquality成功とみなさず、4 jobのremote xcresultが揃うまでrelease blockerを維持する。Instruments Leaks/Allocationsは管理者認証を伴うmanual gateであり、CIのTSan gateへ混在させない。

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

## 利用計測（pseudonymous telemetry）

配布後の利用状況を把握するため、アプリ起動時に利用pingをUTC日ごとに最大1回送信する。設計判断はADR [`002-anonymous-usage-telemetry`](../adr/002-anonymous-usage-telemetry.html)。

- **opt-out（既定ON）**: 設定「表示 > プライバシー > 匿名の利用統計を送信する」で停止できる。OFFへ変更するとin-flight transport/retry sleepをcancelし、OFFの間は通常pingを一切送らない。userが明示したserver delete requestだけはOFF中も許可する。
- **送信・保存する項目**: stableでhigh-entropyなrandom install UUIDは匿名ではなく**仮名識別子（pseudonymous identifier）**である。これにアプリ版 / macOS版 / CPUアーキ / localeを加える。server側でCloudflareの国codeを付加するがIPは保存しない。file/image/prompt/user名などの個人的contentは送らない。
- **保存とretention**: D1はinstall UUID、アプリ版、macOS版、CPUアーキ、locale、国code、初回/最終送信時刻、active day数をinstallごとに1行保存する。最終送信から400日を超えた行はscheduled handlerで削除する。
- **client**: process-global `TelemetryCoordinator`がin-flight/retry Taskを最大1個所有する。`POST /v1/ping`の2xx確認後だけ`UserDefaults`へUTC送信日を記録する。transport/429/5xxは初回+最大2回（1秒、2秒backoff）まで再試行し、失敗後は次回launchへ残す。
- **削除**: Settingsの「仮名IDをサーバーから削除してリセット」は旧UUIDを`POST /v1/delete`へ送り、2xx後だけ旧markerを消して新UUIDを生成する。失敗時は旧UUIDを維持し、UIから再試行できる。delete中はpingをcancelして終了を待つため競合しない。
- **server**: 自前hostのCloudflare Worker + D1（`cloudflare/aiview-metrics/`）。`POST /v1/ping` / `POST /v1/delete`、Bearer header認証の`GET /stats`を提供する。deploy・集計手順は同directoryのREADMEを参照。

### v2 release gate（2026-08-11時点）

repository内のWorker/clientはcompile・local D1 test・dry-run済みだが、staging/productionのD1 migration、Worker deploy、HTTP smokeは外部状態を変更するため未実施。`v0.10.0`のclientを先にreleaseしてはならない。リリース前に次の順で運用者が実施する:

1. staging D1 migrationとWorker deploy後、v2 ping/delete/stats/rate limit/no-storeをsmoke test。
2. production D1 exportを取得し、migration list/apply、Worker deploy。旧GETと新POSTの両方をsmoke test。
3. server v2の証跡を保存してからclientをrelease。90日後にlegacy GET trafficを確認し、routeを削除。

### 集計の確認

```bash
read -r STATS_KEY < cloudflare/aiview-metrics/.stats-key
printf 'header = "Authorization: Bearer %s"\n' "${STATS_KEY}" \
  | curl --config - --fail-with-body --silent --show-error \
  "https://aiview-metrics.rr-yamamoto.workers.dev/stats" \
  | python3 -m json.tool
unset STATS_KEY
```

`STATS_KEY` は Worker の secret（ローカルは `cloudflare/aiview-metrics/.stats-key`、gitignore）。
