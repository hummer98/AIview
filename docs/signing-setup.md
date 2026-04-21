# Signing & Notarization Setup

## このドキュメントについて

AIview を Developer ID で署名し Apple に公証 (Notarization) させて Homebrew Cask 経由で配布するために、**メンテナーが初回に一度だけ行う作業**を集約する。

- **想定読者**: AIview の新規メンテナー、または鍵・証明書・トークンを更新する既存メンテナー
- **想定頻度**: 基本的に一度きり（鍵の有効期限切れ・紛失時のみ再訪）
- **関連ドキュメント**:
  - [`release.md`](release.md) — リリースのたびに実行する日常手順（本ドキュメントの姉妹編）
  - [`../homebrew-aiview/README.md`](../homebrew-aiview/README.md) — エンドユーザー向けの Homebrew インストール手順
  - [Issue #1 - Distribution automation](https://github.com/hummer98/AIview/issues/1) — 配布自動化のトラッキング Issue

> 本ドキュメントは「どこで何を取得し、どう保管するか」に専念する。「取得済みの鍵でどうビルド・公証するか」は [`release.md`](release.md) を参照。両者で重複する詳細（ノータリゼーションの実行コマンド、トラブルシューティングの詳細など）は `release.md` 側を正とする。

---

## 0. 前提

- macOS 開発機
- Xcode 15.0 以降（Command Line Tools を含む）
- `gh` CLI がセットアップ済み（`gh auth login` 完了）
- Apple Developer Program にすでに登録済み（個人 99 USD/年 または Organization）

> Apple Developer Program 未登録の場合は、先に [Apple Developer Program](https://developer.apple.com/programs/) で年次登録を完了させる。支払い承認まで数日かかることがある。

---

## 1. Apple Developer Program 設定

### Team ID の確認

1. https://developer.apple.com/account を開く
2. `Membership details` → `Team ID`
3. 10 文字の英数字（例: `ABCD1234EF`）を控える

> 以降、このドキュメントでは `<YOUR_TEAM_ID>` をプレースホルダとして扱う。

### 規約同意状況の確認

Apple Developer アカウントのホーム画面に `Program License Agreement` 等の同意待ち警告が出ていないか確認する。出ていると証明書発行や notarize が拒否されることがある。

---

## 2. Developer ID Application 証明書の作成と書き出し

notarize 対象のバイナリは **Developer ID Application** 証明書で署名されている必要がある。Mac App Store 用の `Apple Distribution` や Xcode が自動生成する `Development` / `Apple Development` 証明書では公証に使えない。

### 作成（どちらか一方を選ぶ）

**(a) Xcode から作成（推奨）**

1. Xcode → Settings → Accounts → 対象チームを選択 → `Manage Certificates…`
2. 左下の `+` → **`Developer ID Application`** を選ぶ
3. 作成完了すると自動で login keychain に入る

> `Developer ID Application (Managed)` のような **Cloud Managed 証明書は notarize に使えない**。`+` メニューから必ず `Developer ID Application` を選ぶ。

**(b) developer.apple.com から作成（CSR 自前生成）**

1. Keychain Access → Certificate Assistant → Request a Certificate from a Certificate Authority → `.certSigningRequest` を保存
2. https://developer.apple.com/account/resources/certificates → `+` → `Developer ID Application` → CSR をアップロード
3. 生成された `.cer` をダウンロードしてダブルクリックし、login keychain に取り込む

### 確認

```bash
security find-identity -v -p codesigning
```

出力に以下のような行が含まれれば OK:

```
1) XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX "Developer ID Application: <Your Name> (<YOUR_TEAM_ID>)"
```

### `.p12` への書き出し（CI 用）

GitHub Actions の CI で署名するために、証明書を秘密鍵ごと `.p12` に書き出して後ほど Secret として登録する。

1. Keychain Access を開き、キーチェーン一覧で `login` を選ぶ
2. カテゴリ `My Certificates` を選び、`Developer ID Application: <Your Name> (<YOUR_TEAM_ID>)` を展開
3. 証明書と秘密鍵の **両方** を選択（Cmd+クリックで複数選択）
4. 右クリック → `Export 2 items…` → 形式 `Personal Information Exchange (.p12)` で保存
5. パスワードを設定する（このパスワードは後で `DEVELOPER_ID_P12_PASSWORD` として Secret 登録するので、パスワードマネージャー等に控えておく）

> 証明書のみを選択すると `.p12` に秘密鍵が入らず CI で署名できない。**必ず秘密鍵ごと書き出すこと**。

### 有効期限の管理

Developer ID Application 証明書の有効期限は **5 年**。失効前に再発行しないと CI が突然失敗する。カレンダー / Reminders に失効日を登録しておく。

---

## 3. App Store Connect API Key の発行

`xcrun notarytool` は Apple ID+パスワードではなく **App Store Connect API Key** (`.p8`) で認証する。

1. https://appstoreconnect.apple.com/access/integrations/api を開き、`Keys` タブに切り替える
2. `Generate API Key` をクリック
   - Name: `AIview Notarize`（任意、識別できれば何でもよい）
   - Access: `Developer` 以上（`App Manager` 推奨。notarize 自体は `Developer` 権限で足りる）
3. 以下 3 点を控える:
   - `.p8` ファイル（**ダウンロードは 1 回限り**。紛失したら該当 Key を revoke して再発行するしかない）
   - **Key ID**（10 文字英数字、例: `ABCD1234EF`）
   - **Issuer ID**（UUID 形式、例: `69a6de7f-xxxx-xxxx-xxxx-xxxxxxxxxxxx`）

### ローカル保管

推奨パス:

```
~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8
```

```bash
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_ABCD1234EF.p8 ~/.appstoreconnect/private_keys/
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_*.p8
```

- リポジトリ内には**絶対に置かない**（`.gitignore` で `*.p8` は除外済み）
- パスワードマネージャーにバックアップをとっておくと、マシン紛失時に Key を失効させずに済む

---

## 4. GitHub Secrets の登録

`.github/workflows/release.yml` と `.github/workflows/update-tap.yml` が実際に参照する Secret を登録する。**workflow が参照する実名と一致させること**。

| Secret | 内容 | 取得元 |
|--------|------|--------|
| `DEVELOPMENT_TEAM` | Apple Developer Team ID（10 文字） | §1 |
| `ASC_KEY_ID` | App Store Connect Key ID（10 文字） | §3 |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID（UUID） | §3 |
| `ASC_PRIVATE_KEY` | `.p8` を `base64 -i` した文字列 | §3 |
| `DEVELOPER_ID_P12` | `.p12` を `base64 -i` した文字列 | §2 |
| `DEVELOPER_ID_P12_PASSWORD` | `.p12` エクスポート時のパスワード | §2 |
| `KEYCHAIN_PASSWORD` | CI 内の一時 keychain 用（自前生成） | `openssl rand -base64 24` |
| `TAP_PAT` | `hummer98/homebrew-aiview` への push 権限を持つ Fine-grained PAT | GitHub Settings |

### 登録コマンド

```bash
# §1 Team ID
gh secret set DEVELOPMENT_TEAM --body "<YOUR_TEAM_ID>"

# §3 App Store Connect API
gh secret set ASC_KEY_ID --body "<ASC_KEY_ID>"
gh secret set ASC_ISSUER_ID --body "<ASC_ISSUER_ID>"
base64 -i ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8 \
  | gh secret set ASC_PRIVATE_KEY

# §2 Developer ID 証明書
base64 -i DeveloperID.p12 | gh secret set DEVELOPER_ID_P12
gh secret set DEVELOPER_ID_P12_PASSWORD --body "<P12_PASSWORD>"

# CI 内一時 keychain 用
openssl rand -base64 24 | gh secret set KEYCHAIN_PASSWORD

# tap 自動更新用
gh secret set TAP_PAT --body "<FINE_GRAINED_PAT>"
```

> `.p8` / `.p12` は必ず `base64 -i <file> | gh secret set <NAME>` のように stdin パイプで登録する。`pbcopy` → 手動貼り付けは改行混入の事故が起きやすいので使わない。

### `TAP_PAT` の作成手順

本リポの `update-tap.yml` が別リポ `hummer98/homebrew-aiview` に push するには、専用の Fine-grained PAT が必要。

1. GitHub → Settings → Developer settings → Personal access tokens → **Fine-grained tokens** → `Generate new token`
2. 設定:
   - Resource owner: `hummer98`
   - Repository access: **Only select repositories** → `hummer98/homebrew-aiview` のみ
   - Repository permissions:
     - `Contents`: **Read and write**
     - `Metadata`: Read-only（自動付与）
   - Expiration: 任意（最大 1 年。失効日をカレンダーに登録）

> `${{ secrets.GITHUB_TOKEN }}` は本リポ内リソースにしか書き込めない。別リポの tap 更新には使えないため、**必ず専用 PAT を発行する**。

### 登録確認

```bash
gh secret list
```

以下 8 件が揃っていれば OK:

```
ASC_ISSUER_ID
ASC_KEY_ID
ASC_PRIVATE_KEY
DEVELOPER_ID_P12
DEVELOPER_ID_P12_PASSWORD
DEVELOPMENT_TEAM
KEYCHAIN_PASSWORD
TAP_PAT
```

---

## 5. ローカル開発時の署名セットアップ

ローカルでも `task archive` や `scripts/notarize.sh` を手動実行できるようにする。

### `Developer.xcconfig` の作成

```bash
cp AIview/Config/Developer.xcconfig.sample AIview/Config/Developer.xcconfig
```

`AIview/Config/Developer.xcconfig` を開き、以下 1 行を自分の Team ID で埋める:

```
DEVELOPMENT_TEAM = <YOUR_TEAM_ID>
```

このファイルは `.gitignore` 済み（`AIview/Config/Developer.xcconfig` 行が登録されている）。

### 絶対にコミットしないファイル一覧

- `AIview/Config/Developer.xcconfig`
- `*.p8` / `*.p12` / `*.pem` / `*.key`
- `.env` / `.env.local`

### コミット前チェック

```bash
git status
```

- `Developer.xcconfig` が `untracked` にも `staged` にも現れないこと
- `.p8` / `.p12` が現れないこと

---

## 6. ノータリゼーションの手動実行

詳細な手順・コマンドは [`release.md` の Release Commands](release.md#release-commands) を参照。本ドキュメントでは「セットアップが正しく終わっているか」を確かめる最低限のスモークテストだけ示す。

```bash
# .env.local に ASC_KEY_ID / ASC_ISSUER_ID / ASC_PRIVATE_KEY_PATH を設定済みである前提
set -a; source .env.local; set +a

task archive
./scripts/notarize.sh --archive build/AIview.xcarchive --version 0.0.0-dev
```

成功時には `dist/AIview-0.0.0-dev.{dmg,zip,dmg.sha256,zip.sha256}` の 4 ファイルが生成される。

Gatekeeper 検証:

```bash
spctl -a -vvv --type install dist/AIview-0.0.0-dev.dmg
```

`accepted source=Notarized Developer ID` と出れば公証まで成功している。

---

## 7. トラブルシューティング

初回セットアップで詰まりやすいポイントのみ記載する。リリース実行時に起きる詳細な症状・対処は [`release.md` の Troubleshooting](release.md#troubleshooting) を参照。

- **`security find-identity` に証明書が出ない**
  §2 で証明書が login keychain に取り込まれていない。Keychain Access を開き直して `My Certificates` に証明書があるか確認する。
- **`.p12` に秘密鍵が入っていない（`security import` で「no identity found」相当のエラー）**
  §2 の export で証明書のみを選んで書き出している。証明書と秘密鍵の**両方**を選択して再エクスポートする。
- **notarytool が `Invalid` を返す**
  `scripts/notarize.sh` が失敗時に `xcrun notarytool log <submission_id>` を自動で stderr に出力する。ログで Hardened Runtime 未有効 / entitlements 不整合 / 依存バイナリ未署名 などを特定する。
- **`stapler staple` が `Could not validate ticket` で失敗**
  Apple CDN への反映待ち。1〜2 分後に再実行。
- **CI の `security import` ステップが失敗**
  `DEVELOPER_ID_P12_PASSWORD` 不一致が大半。ローカルで `security import DeveloperID.p12 -P "<pass>" -k /tmp/test.keychain-db` が通るか事前に検証する。
- **`update-tap.yml` が 403 を返す**
  `TAP_PAT` の期限切れか権限不足。§4 の手順で再発行し `gh secret set TAP_PAT` で上書きする。

---

## 8. （将来）Sparkle 自動アップデート用シークレット

**現時点では未対応**。AIview が将来 [Sparkle](https://sparkle-project.org/) による自動アップデートに対応するときは、以下の追加 Secret が必要になる見込み:

- `SPARKLE_ED25519_PRIVATE_KEY` — appcast 署名用 ed25519 秘密鍵
- appcast XML のホスト先（GitHub Pages / S3 / 独自ドメイン等）の選定

本章は章立てのみ確保したプレースホルダ。導入時に手順を埋める。

---

## Appendix: Secret 一覧早見表

§4 の表を末尾でも参照できるよう再掲する。

| Secret | 内容 | 取得元 |
|--------|------|--------|
| `DEVELOPMENT_TEAM` | Apple Developer Team ID（10 文字） | §1 |
| `ASC_KEY_ID` | App Store Connect Key ID（10 文字） | §3 |
| `ASC_ISSUER_ID` | App Store Connect Issuer ID（UUID） | §3 |
| `ASC_PRIVATE_KEY` | `.p8` を `base64 -i` した文字列 | §3 |
| `DEVELOPER_ID_P12` | `.p12` を `base64 -i` した文字列 | §2 |
| `DEVELOPER_ID_P12_PASSWORD` | `.p12` エクスポート時のパスワード | §2 |
| `KEYCHAIN_PASSWORD` | CI 内の一時 keychain 用（自前生成） | `openssl rand -base64 24` |
| `TAP_PAT` | `hummer98/homebrew-aiview` への push 権限を持つ Fine-grained PAT | GitHub Settings |

workflow 内ビルトインの `GITHUB_TOKEN` は自動提供のため本ドキュメントの管理対象外。
