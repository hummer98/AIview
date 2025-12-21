# Bug Report: delete-fails-on-volume-without-trash

## Overview
Dを押すとファイル削除に失敗する。ボリューム"Text2Img"にゴミ箱がないため、ファイルをゴミ箱に移動できないエラーが発生。

## Status
**Pending**

## Environment
- Date Reported: 2025-12-21T00:00:00+09:00
- Affected Component: *To be identified during analysis*
- Severity: *To be determined*

## Steps to Reproduce
*To be documented*

1. 外部ボリューム "Text2Img" 上のファイルを選択
2. Dキーを押して削除を試みる
3. エラーが発生

## Expected Behavior
*To be documented*

## Actual Behavior
エラーメッセージ: 「削除に失敗しました: 2025-01-05_03-48-53_5511.png (ボリューム"Text2Img"にはゴミ箱がないため、"2025-01-05_03-48-53_5511.png"をゴミ箱に入れることができませんでした。)」

## Error Messages / Logs
```
削除に失敗しました: 2025-01-05_03-48-53_5511.png (ボリューム"Text2Img"にはゴミ箱がないため、"2025-01-05_03-48-53_5511.png"をゴミ箱に入れることができませんでした。)
```

## Related Files
- *To be identified during analysis*

## Additional Context
外部ボリュームやネットワークドライブではゴミ箱機能がサポートされていない場合がある。直接削除のフォールバック処理が必要な可能性あり。
