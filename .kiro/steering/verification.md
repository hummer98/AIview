# Verification Commands

spec-inspection 実行時に自動実行される検証コマンドを定義します。

## Commands

| Type | Command | Workdir | Description |
|------|---------|---------|-------------|
| build | task build | . | Xcode デバッグビルド |
| test | task test | . | ユニットテスト + UIテスト |
| lint | task lint | . | SwiftLint による静的解析 |

## Notes

- **Task Runner**: このプロジェクトは [go-task](https://taskfile.dev/) を使用
- **build**: `xcodebuild` によるデバッグビルド
- **test**: Unit Tests (`AIviewTests/`) + UI Tests (`AIviewUITests/`) を実行
  - Performance Tests は時間がかかるため default suite から除外
- **lint**: SwiftLint による Swift コードスタイルチェック
- **format**: `task format` で SwiftFormat による自動整形（検証対象外）

### 手動実行コマンド

パフォーマンステストなど、CI/検証に含めない特別なコマンド:

```bash
# パフォーマンステスト（手動実行のみ）
task test:perf        # 全パフォーマンステスト
task test:perf:memory # メモリ使用量テスト

# コードフォーマット
task format           # SwiftFormat による自動整形
task format:check     # フォーマット差分チェック
```

---
_検証コマンドは spec-inspection 時に自動実行されます_
