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

### CI / GitHub Actions (future)

GitHub Actions workflow 化は別タスク (Issue #1 Phase 2) で実装予定。想定する大枠のみ記しておく。

```yaml
# .github/workflows/release.yml (抜粋・擬似コード)
jobs:
  release:
    runs-on: macos-14
    steps:
      - uses: actions/checkout@v4

      - name: Write .p8 from secret
        env:
          ASC_PRIVATE_KEY_BASE64: ${{ secrets.ASC_PRIVATE_KEY_BASE64 }}
        run: |
          mkdir -p "$RUNNER_TEMP/keys"
          echo "$ASC_PRIVATE_KEY_BASE64" | base64 -d > "$RUNNER_TEMP/keys/AuthKey.p8"
          chmod 600 "$RUNNER_TEMP/keys/AuthKey.p8"
          echo "ASC_PRIVATE_KEY_PATH=$RUNNER_TEMP/keys/AuthKey.p8" >> "$GITHUB_ENV"

      - name: Import Developer ID certificate
        # security import ... (別途実装)

      - name: Archive
        run: task archive

      - name: Notarize & package
        env:
          ASC_KEY_ID: ${{ secrets.ASC_KEY_ID }}
          ASC_ISSUER_ID: ${{ secrets.ASC_ISSUER_ID }}
        run: ./scripts/notarize.sh --archive build/AIview.xcarchive --version ${{ github.ref_name }}

      - uses: actions/upload-artifact@v4
        with:
          name: dist
          path: dist/
```

必要な GitHub Secrets:

| Secret | 中身 |
|--------|------|
| `ASC_KEY_ID` | API Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_PRIVATE_KEY_BASE64` | `.p8` を `base64 -i AuthKey_*.p8` した文字列 |
| `DEVELOPER_ID_CERT_BASE64` | Developer ID Application `.p12` を `base64` したもの |
| `DEVELOPER_ID_CERT_PASSWORD` | 上記 `.p12` のパスワード |

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
- [ ] GitHub Secrets (`ASC_KEY_ID` / `ASC_ISSUER_ID` / `ASC_PRIVATE_KEY_BASE64` / 証明書一式) を登録
- [ ] GitHub Actions workflow を新規実装 (別タスク)

---

**関連ファイル**:

- `scripts/notarize.sh` — 本手順で呼び出すエントリポイント
- `AIview/Config/Signing.xcconfig` — 署名共通設定（hardened runtime 有効化ほか）
- `AIview/Config/Developer.xcconfig.sample` — 個別設定のテンプレート
- `Taskfile.yml` — `task archive` / `task lint:sh` など
