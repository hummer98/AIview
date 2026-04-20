# Contributing to AIview

Thank you for your interest in contributing to AIview!

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/AIview.git`
3. Open `AIview.xcodeproj` in Xcode
4. Create a feature branch: `git checkout -b feature/your-feature-name`

## Development Setup

### Requirements

- macOS 14.0+
- Xcode 15.0+

### Signing Setup (Developer.xcconfig)

AIview は Developer ID Application 証明書で署名して配布します。Team ID は開発者ごとに異なるため、`Developer.xcconfig` というローカルファイルで注入します。

#### 手順

1. テンプレートをコピー:
   ```bash
   cp AIview/Config/Developer.xcconfig.sample AIview/Config/Developer.xcconfig
   ```

2. `AIview/Config/Developer.xcconfig` を編集し、`DEVELOPMENT_TEAM` にあなたの Team ID を設定:
   ```
   DEVELOPMENT_TEAM = ABCD1234EF
   ```

3. Team ID は Apple Developer Portal で確認:
   - https://developer.apple.com/account にログイン
   - 左サイドバー「Membership details」を開く
   - 「Team ID」欄の 10 文字の英数字がそれ

#### 補足

- `Developer.xcconfig` は `.gitignore` 済みなのでコミットされない
- `Developer.xcconfig` を作らなくても `task build` / `task test` は動作する（ad-hoc 署名にフォールバック）
- Archive / Notarize する場合は Team ID の設定が必須
- `ABCD1234EF` は placeholder。動作確認のみ行う場合は `DEVELOPMENT_TEAM =`（空値）に書き換えるか、ファイル自体を作らない
- Automatic 署名が必要な場合は `CODE_SIGN_STYLE = Automatic` を手動で追記（Team ID と必ずセットで設定すること。空 Team で Automatic 指定すると Exit 65 になる）

#### Xcode GUI 運用ルール

- **Signing & Capabilities タブで Team を設定しないこと**。GUI で Team を選ぶと pbxproj の `TargetAttributes` に `DevelopmentTeam = XXXX;` が書き込まれ、xcconfig 経由の Team 注入設計が崩れる
- 署名設定の変更は `Developer.xcconfig` または `Signing.xcconfig` で行う
- pbxproj は手編集されているため、Xcode で開くと順序ソート等で差分が発生する場合がある

### Building

```bash
open AIview.xcodeproj
# Build with ⌘B, Run with ⌘R
```

### Running Tests

```bash
# In Xcode: ⌘U
# Or via command line:
xcodebuild test -project AIview.xcodeproj -scheme AIview
```

## Code Style

- Follow Swift API Design Guidelines
- Use SwiftUI for new UI components
- Prefer async/await over completion handlers
- Use `Task.isCancelled` checks in long-running operations

## Pull Request Process

1. Ensure your code builds without warnings
2. Run all tests and ensure they pass
3. Update documentation if needed
4. Create a Pull Request with a clear description

### PR Title Format

Use conventional commit style:

- `feat: Add new feature`
- `fix: Fix bug description`
- `docs: Update documentation`
- `refactor: Refactor code`
- `test: Add tests`

## Reporting Issues

When reporting bugs, please include:

- macOS version
- Steps to reproduce
- Expected vs actual behavior
- Screenshots if applicable

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
