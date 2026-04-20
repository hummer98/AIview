# homebrew-aiview

[AIview](https://github.com/hummer98/AIview) の Homebrew Cask を配布する tap です。

AIview は macOS 向けの高速な画像ビューアです。本 tap は [hummer98/AIview](https://github.com/hummer98/AIview) の公式 release 成果物 (`AIview-<version>.zip`) を署名・notarize 済みバイナリとして配布します。

## Requirements

- macOS 14.0 (Sonoma) 以降
- [Homebrew](https://brew.sh)

## Install

```bash
brew tap hummer98/aiview
brew install --cask aiview
```

インストール後、`AIview.app` は `/Applications` 配下に配置されます。初回起動時に macOS の Gatekeeper が Developer ID 署名と公証を検証します (オフラインでも成功)。

## Update

```bash
brew update
brew upgrade --cask aiview
```

新バージョンのリリース時、[hummer98/AIview](https://github.com/hummer98/AIview) の GitHub Actions (`update-tap.yml`) が自動で本 tap の `Casks/aiview.rb` を更新します。

## Uninstall

```bash
# アプリ本体のみ削除
brew uninstall --cask aiview

# アプリ + 設定・キャッシュ等を完全削除 (zap)
brew uninstall --zap --cask aiview
```

> **Note**: 画像フォルダ配下に作成される `.aiview/` ディレクトリ (`favorites.json`, `thumbnails/`) はユーザーデータ扱いで、zap の対象外です。必要に応じて手動で削除してください。

## License

MIT License. 詳細は [LICENSE](LICENSE) を参照。

本 tap に含まれる Cask formula は [hummer98/AIview](https://github.com/hummer98/AIview) 本体と同じライセンスで配布されます。配布対象のアプリケーション自体のライセンスについても AIview 本体リポジトリの [LICENSE](https://github.com/hummer98/AIview/blob/master/LICENSE) を参照してください。

## Links

- 本体リポジトリ: https://github.com/hummer98/AIview
- Issue / Bug Report: https://github.com/hummer98/AIview/issues
