# Bug Report: folder-open-mode-reset

## Overview
スライドショー状態で新しいフォルダを開いた時に、スライドショーモードが自動的に解除されない

## Status
**In Analysis**

## Environment
- Date Reported: 2026-01-14T00:00:00+09:00
- Affected Component: ImageBrowserViewModel
- Severity: Medium

## Steps to Reproduce
1. アプリケーションを起動し、画像が含まれるフォルダを開く
2. メニューから「スライドショー開始」を選択
3. スライドショーが再生中の状態で、別のフォルダを開く（メニュー > フォルダを開く）
4. 新しいフォルダが開かれた後もスライドショーが継続する

## Expected Behavior
新しいフォルダを開いた時、スライドショーが自動的に停止し、通常の閲覧モードに戻る

## Actual Behavior
スライドショーが継続し、新しいフォルダの画像が自動的に切り替わり続ける

## Error Messages / Logs
```
なし（エラーは発生しない）
```

## Related Files
- `AIview/Sources/Domain/ImageBrowserViewModel.swift` - openFolder() メソッド (192-246行目)

## Additional Context
- お気に入りフィルターモードは `openFolder()` 内で正しくリセットされている（209-210行目）
- スライドショー関連の状態（`isSlideshowActive`, `isSlideshowPaused`, `slideshowTimer`）のリセットが欠落
