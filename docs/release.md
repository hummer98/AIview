# Release Procedure

AIview を配布用にビルド・署名・ノータリゼーション (notarize) し、`.dmg` / `.zip` を生成する手順。

`scripts/notarize.sh` が処理の中心。本ドキュメントはその事前準備と実行例をまとめる。

---

## Prerequisites

### 1. Developer ID Certificate

- Apple Developer Program (有償) のメンバーシップが必要。
- Xcode → Settings → Accounts → `(team)` → Manage Certificates… から **Developer ID Application** 証明書を作成し、macOS キーチェーンに保存する。
- CLI で確認:

  ```bash
  security find-identity -v -p codesigning
  ```

  出力に `"Developer ID Application: <Your Team> (<TEAMID>)"` が含まれていれば OK。

### 2. App Store Connect API Key (.p8)

notarytool は Apple ID+パスワード認証ではなく **App Store Connect API Key** による認証を使う。

1. [App Store Connect → Users and Access → Integrations → Keys](https://appstoreconnect.apple.com/access/integrations/api) を開く。
2. `Generate API Key` をクリックし、Name に任意の名前（例: `AIview Notarize`）、Access には **Developer** 以上（`App Manager` 推奨）を割り当てて発行。
3. `.p8` ファイルをダウンロードする。
   - **重要: `.p8` はダウンロード後に再取得できない。** 紛失したら鍵を失効させて作り直すしかない。
4. 発行ページに表示される **Key ID** (例: `ABCD1234EF`) と **Issuer ID** (UUID 形式) を控える。

### 3. `.p8` の配置

Xcode の慣習に合わせて次のパスを推奨:

```
~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

- リポジトリ内には**絶対に置かない**。`.gitignore` で `.env*`, `*.pem`, `*.key`, `*.p8` は除外済み。
- パーミッションは `chmod 600 ~/.appstoreconnect/private_keys/AuthKey_*.p8` 推奨。

### 4. Project Signing Config

- `AIview/Config/Developer.xcconfig` を用意し `DEVELOPMENT_TEAM = <TEAMID>` を設定する（サンプル: `AIview/Config/Developer.xcconfig.sample`）。このファイルは `.gitignore` 済み。
- `ENABLE_HARDENED_RUNTIME = YES` は `Signing.xcconfig` で既に共通設定済み。notarize 時の必須要件のため変更しない。

### 5. Local Environment Variables

`scripts/notarize.sh` は次の環境変数を要求する。

| 変数 | 意味 | 例 |
|------|------|----|
| `ASC_KEY_ID` | 上記 2 で控えた Key ID | `ABCD1234EF` |
| `ASC_ISSUER_ID` | 上記 2 で控えた Issuer ID (UUID) | `69a6de7f-xxxx-xxxx-xxxx-xxxxxxxxxxxx` |
| `ASC_PRIVATE_KEY_PATH` | `.p8` ファイルの**絶対パス** | `/Users/me/.appstoreconnect/private_keys/AuthKey_ABCD1234EF.p8` |

設定方法の例:

- **`.env.local`** (gitignore 済):

  ```bash
  # .env.local
  ASC_KEY_ID=ABCD1234EF
  ASC_ISSUER_ID=69a6de7f-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  ASC_PRIVATE_KEY_PATH=/Users/me/.appstoreconnect/private_keys/AuthKey_ABCD1234EF.p8
  ```

  ```bash
  set -a; source .env.local; set +a
  ./scripts/notarize.sh --archive build/AIview.xcarchive --version 0.3.0
  ```

- **direnv** (`.envrc`):

  ```bash
  export ASC_KEY_ID=ABCD1234EF
  export ASC_ISSUER_ID=69a6de7f-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  export ASC_PRIVATE_KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_ABCD1234EF.p8"
  ```

- **1Password CLI** (シークレット参照):

  ```bash
  op run --env-file=.env.1password.local -- ./scripts/notarize.sh --archive build/AIview.xcarchive --version 0.3.0
  ```

---

## Release Commands

### Local (Manual)

```bash
# 1. Archive をビルド (Release configuration, Developer ID 署名)
task archive
# → build/AIview.xcarchive が生成される

# 2. Notarize → staple → dmg/zip/sha256 を生成
./scripts/notarize.sh --archive build/AIview.xcarchive --version 0.3.0
```

直接 `.app` を指定する場合:

```bash
./scripts/notarize.sh --app path/to/AIview.app --version 0.3.0
```

成功すると `./dist/` 配下に次の 4 ファイルが生成される:

```
dist/AIview-0.3.0.zip
dist/AIview-0.3.0.zip.sha256
dist/AIview-0.3.0.dmg
dist/AIview-0.3.0.dmg.sha256
```

所要時間の目安: ノータリゼーションの待ちが数分〜十数分。`--wait` が同期的に block するため、完了まで端末はそのまま開いておく。

### CI / GitHub Actions

`.github/workflows/release.yml` が自動化を担当する。トリガーは 2 通り:

1. **タグ push (`v*.*.*`)**: `release` ジョブが archive → 署名 → 公証 → staple → `.dmg` / `.zip` / `.sha256` 生成 → GitHub Release を作成する。`v0.3.0-rc.1` のように `-` を含む SEMVER prerelease は GitHub Release 側も pre-release 扱いになる。
2. **`workflow_dispatch`**: `release-dry-run` ジョブが同一経路で archive〜notarize まで実行し、生成物は `actions/upload-artifact@v4` で `dist-dryrun-<VERSION>` という名前の artifact に保管される（保持期間 7 日）。GitHub Release は作成されず、タグも打たれない。

Runner は `macos-14`、Xcode は `maxim-lobanov/setup-xcode@v1` で `XCODE_VERSION` 環境変数（現在 `15.4`）に固定している。Xcode を変更するときは workflow の `env.XCODE_VERSION` と本ドキュメントを同時に更新すること。

#### 必要な GitHub Secrets

| Secret | 中身 |
|--------|------|
| `ASC_KEY_ID` | App Store Connect API Key ID (例: `ABCD1234EF`) |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID (UUID) |
| `ASC_PRIVATE_KEY` | `.p8` を `base64 -i AuthKey_*.p8` した Base64 文字列 |
| `DEVELOPER_ID_P12` | Developer ID Application `.p12` を `base64 -i` した Base64 文字列 |
| `DEVELOPER_ID_P12_PASSWORD` | `.p12` エクスポート時に設定したパスワード |
| `KEYCHAIN_PASSWORD` | CI 内で生成する一時キーチェーン用のパスワード (`openssl rand -base64 24` 等で生成) |
| `DEVELOPMENT_TEAM` | Apple Developer Team ID (10 文字、例: `ABCD1234EF`) |

#### Secrets 登録手順 (`gh` CLI)

```bash
gh secret set ASC_KEY_ID --body "ABCD1234EF"
gh secret set ASC_ISSUER_ID --body "69a6de7f-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
base64 -i ~/.appstoreconnect/private_keys/AuthKey_ABCD1234EF.p8 | gh secret set ASC_PRIVATE_KEY
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12
gh secret set DEVELOPER_ID_P12_PASSWORD --body "<p12 password>"
openssl rand -base64 24 | gh secret set KEYCHAIN_PASSWORD
gh secret set DEVELOPMENT_TEAM --body "ABCD1234EF"
```

`.p8` / `.p12` は必ず `base64 -i <file> | gh secret set <NAME>` のように stdin パイプで登録する（`pbcopy` → 手動貼り付けは改行混入の事故が起きやすいので使わない）。

#### タグ打ち前チェックリスト

1. `CHANGELOG.md` を更新する。
2. `CFBundleShortVersionString` / `CFBundleVersion`（`AIview/Info.plist` または xcconfig）を更新する。
3. ローカルで以下が通ることを確認する。
   ```bash
   task archive
   ./scripts/notarize.sh --archive build/AIview.xcarchive --version <ver>
   ```
4. `workflow_dispatch` で dry-run を走らせて成功することを確認する。
   ```bash
   gh workflow run release.yml -f dry_run_version=<ver>
   gh run watch
   gh run download --name dist-dryrun-<ver>
   ```
5. `git tag vX.Y.Z && git push origin vX.Y.Z` でタグを push し、Actions の `release` ジョブが通ることを確認する。

#### Dry-run 手順

```bash
gh workflow run release.yml -f dry_run_version=0.3.0
gh run watch
gh run download --name dist-dryrun-0.3.0
```

タグを作らずに Secrets / キーチェーン / 署名 / 公証の全経路を検証できる。`dry_run_version` には `0.3.0` や `0.3.0-rc.1` のような SEMVER を渡す（先頭の `v` は不要、workflow 側で SEMVER 形式を検証する）。

#### トラブルシューティング (CI)

- **`notarytool submission status = Invalid`**: `scripts/notarize.sh` が失敗時に `xcrun notarytool log <submission_id>` を自動で stderr にダンプする。Actions ログの `Notarize & package` ステップの末尾に submission id と log 内容が出るので確認する。よくある原因は上記 [Troubleshooting](#troubleshooting) と同じ。
- **`security import` 失敗**: `.p12` のパスワード誤り、またはファイル形式不一致が多い。ローカルで `security import DeveloperID.p12 -P "<pass>" -v -A -t cert -f pkcs12 -k /tmp/test.keychain-db` が通るか確認した上で、`DEVELOPER_ID_P12_PASSWORD` を再登録する。
- **`.p12` 期限切れ**: Keychain Access から "Developer ID Application" 証明書＋秘密鍵を新しい `.p12` にエクスポートし、`base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12` で更新する。パスワードも併せて `gh secret set DEVELOPER_ID_P12_PASSWORD` で差し替える。
- **`xcodebuild -allowProvisioningUpdates` が profile 自動取得に失敗**: `DEVELOPMENT_TEAM` secret と `Write Developer.xcconfig` ステップの出力が正しいか（`DEVELOPMENT_TEAM = <TEAMID>` が 1 行書かれているか）を確認する。
- **`security set-key-partition-list` 系で codesign が partition list プロンプトで block**: `-S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD"` を workflow 末尾で再発行すれば回避できる。
- **Xcode バージョン削除による失敗**: `maxim-lobanov/setup-xcode@v1` が `env.XCODE_VERSION` を見つけられない場合は、当該バージョンが runner から削除されたことを意味する。暫定対応として `macos-latest` へフォールバックするか、新しい `XCODE_VERSION` に更新する。

---

## Output Artifacts

`scripts/notarize.sh` が成功すると `./dist/` 配下に次のファイルが揃う。

| ファイル | 用途 |
|----------|------|
| `AIview-<ver>.dmg` | 配布用ディスクイメージ（`Applications` symlink 付き、Gatekeeper 用に staple 済） |
| `AIview-<ver>.zip` | `.app` バンドルを保持した zip（Sparkle / 直リンク配布用） |
| `AIview-<ver>.dmg.sha256` | dmg の SHA-256（Homebrew Cask などで利用） |
| `AIview-<ver>.zip.sha256` | zip の SHA-256 |

すべての成果物に **公証チケットが staple** されているため、配布先の macOS がオフラインでも Gatekeeper が即座に検証可能。

---

## Troubleshooting

### `codesign -vv --deep --strict` が失敗する

- `AIview/Config/Developer.xcconfig` の `DEVELOPMENT_TEAM` が未設定 / 誤っている可能性が高い。
- `security find-identity -v -p codesigning` で Developer ID Application 証明書がキーチェーンに入っているか確認。
- Debug ビルドには ad-hoc 署名 (`CODE_SIGN_IDENTITY = -`) が当たるので、notarize には **必ず `task archive` (Release configuration) の出力を使うこと**。

### notarytool の status が `Invalid`

```bash
xcrun notarytool log <submission_id> \
  --key "$ASC_PRIVATE_KEY_PATH" \
  --key-id "$ASC_KEY_ID" \
  --issuer "$ASC_ISSUER_ID"
```

`scripts/notarize.sh` は失敗時に自動で上記を stderr にダンプする。よくある原因:

- `ENABLE_HARDENED_RUNTIME` が無効 → `Signing.xcconfig` を確認
- 二次依存 (embedded framework, helper binary) が未署名 → `codesign --deep` が効かない場合は個別署名
- `com.apple.security.cs.disable-library-validation` など entitlements 不整合 → `AIview.entitlements` を見直す
- 古い `notarytool` → `xcrun --find notarytool` が Xcode 13 以降を指すように `xcode-select -s` で切り替える

### `xcrun stapler staple` が `Could not validate ticket` で失敗する

Apple CDN のチケット反映に数十秒〜数分かかる場合がある。notarytool 成功直後に staple が失敗したときは 1〜2 分待って再実行。

### `.dmg` の staple が警告を出すが続行する

`scripts/notarize.sh` は `.app` 本体に staple できていれば `.dmg` の staple 失敗は warning 扱いで継続する（Gatekeeper は `.app` の staple を優先検証するため）。致命的ではない。

---

## Appendix: Issue #1 Phase 2 Checklist

配布自動化 (Issue #1) の Phase 2 で対応する項目:

- [ ] Apple Developer Program 契約 & Developer ID Application 証明書発行
- [ ] App Store Connect API Key 発行 & `.p8` 安全保管
- [ ] `AIview/Config/Developer.xcconfig` にチーム ID を設定してローカルで `task archive` が通ることを確認
- [ ] ローカルで `scripts/notarize.sh` を実行し、`dist/AIview-<ver>.{dmg,zip}` が生成され `spctl -a -vvv --type install AIview-<ver>.dmg` が `accepted source=Notarized Developer ID` を返すことを確認
- [ ] GitHub Secrets (`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY` / `DEVELOPER_ID_P12` / `DEVELOPER_ID_P12_PASSWORD` / `KEYCHAIN_PASSWORD` / `DEVELOPMENT_TEAM`) を登録
- [x] GitHub Actions workflow を新規実装 (`.github/workflows/release.yml`)

---

**関連ファイル**:

- `scripts/notarize.sh` — 本手順で呼び出すエントリポイント
- `AIview/Config/Signing.xcconfig` — 署名共通設定（hardened runtime 有効化ほか）
- `AIview/Config/Developer.xcconfig.sample` — 個別設定のテンプレート
- `Taskfile.yml` — `task archive` / `task lint:sh` など
