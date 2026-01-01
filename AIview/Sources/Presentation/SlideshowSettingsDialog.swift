import SwiftUI

/// スライドショー設定ダイアログ
/// Requirements: 1.1, 1.2, 1.3, 7.2, 8.3
struct SlideshowSettingsDialog: View {
    /// 画像が存在するかどうか
    let hasImages: Bool
    /// 開始ボタン押下時のコールバック
    let onStart: (Int) -> Void
    /// キャンセル時のコールバック
    let onCancel: () -> Void

    /// 表示間隔（秒）
    @State private var interval: Double

    init(hasImages: Bool, initialInterval: Int, onStart: @escaping (Int) -> Void, onCancel: @escaping () -> Void) {
        self.hasImages = hasImages
        self.onStart = onStart
        self.onCancel = onCancel
        _interval = State(initialValue: Double(initialInterval))
    }

    var body: some View {
        VStack(spacing: 24) {
            // タイトル
            Text("スライドショー設定")
                .font(.headline)

            // 間隔スライダー
            VStack(spacing: 8) {
                HStack {
                    Text("表示間隔")
                    Spacer()
                    Text("\(Int(interval))秒")
                        .monospacedDigit()
                        .foregroundColor(.secondary)
                }

                Slider(value: $interval, in: 1...60, step: 1)
                    .tint(.accentColor)

                HStack {
                    Text("1秒")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("60秒")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            // キーボード操作ヘルプ
            VStack(alignment: .leading, spacing: 8) {
                Text("キーボード操作")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    helpRow(key: "Space", description: "一時停止 / 再開")
                    helpRow(key: "ESC", description: "スライドショー終了")
                    helpRow(key: "← →", description: "前後の画像に移動")
                    helpRow(key: "↑ ↓", description: "間隔を1秒ずつ調整")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // ボタン
            HStack(spacing: 12) {
                Button("キャンセル") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)

                Button("開始") {
                    onStart(Int(interval))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasImages)
            }
        }
        .padding(24)
        .frame(width: 320)
    }

    @ViewBuilder
    private func helpRow(key: String, description: String) -> some View {
        HStack(spacing: 12) {
            Text(key)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.secondary.opacity(0.2))
                )
                .frame(width: 60)

            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    SlideshowSettingsDialog(
        hasImages: true,
        initialInterval: 3,
        onStart: { interval in
            print("Start with interval: \(interval)")
        },
        onCancel: {
            print("Cancelled")
        }
    )
}
