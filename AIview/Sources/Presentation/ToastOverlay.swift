import SwiftUI

/// トースト通知を表示するオーバーレイコンポーネント
/// Requirements: 1.5, 3.3, 3.4, 5.3, 6.2
struct ToastOverlay: View {
    /// 表示するメッセージ（nilで非表示）
    let message: String?
    /// トースト非表示時に呼ばれるコールバック
    let onDismiss: () -> Void

    /// アニメーション用の不透明度
    @State private var opacity: Double = 0

    /// 自動非表示までの時間（秒）
    private let dismissDelay: Double = 2.0

    var body: some View {
        ZStack(alignment: .bottom) {
            // コンテンツは表示しない（オーバーレイのみ）
            Color.clear

            if let message = message {
                toastView(message: message)
                    .padding(.bottom, 120)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: message)
        .onChange(of: message) { _, newValue in
            if newValue != nil {
                scheduleAutoDismiss()
            }
        }
    }

    @ViewBuilder
    private func toastView(message: String) -> some View {
        Text(message)
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(.ultraThinMaterial)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.black.opacity(0.6))
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 10, x: 0, y: 4)
    }

    private func scheduleAutoDismiss() {
        // 既存のタイマーをキャンセルして新しいタイマーを開始
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(dismissDelay * 1_000_000_000))
            onDismiss()
        }
    }
}

#Preview {
    ZStack {
        Color.black
        ToastOverlay(message: "スライドショー開始 3秒間隔") {}
    }
    .frame(width: 800, height: 600)
}
