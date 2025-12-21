# Project

## Minimal Workflow

### Bug Fix (Lightweight Workflow)

小規模なバグ修正にはフルSDDプロセスは不要。以下の軽量ワークフローを使用：

```
Report → Analyze → Fix → Verify
```

| コマンド | 説明 |
|---------|------|
| `/kiro:bug-create <name> "description"` | バグレポート作成 |
| `/kiro:bug-analyze [name]` | 根本原因の調査 |
| `/kiro:bug-fix [name]` | 修正の実装 |
| `/kiro:bug-verify [name]` | 修正の検証 |
| `/kiro:bug-status [name]` | 進捗確認 |

**使い分け**:
- **小規模バグ**: Bug Fixワークフロー（軽量・高速）
- **設計変更を伴う複雑なバグ**: Full SDDワークフロー
