import SwiftUI

/// 自動dismissの世代identity。新しいtoast開始後に旧Taskが完了してもcurrentを消さない。
struct ToastDismissalGeneration {
    private(set) var current: UUID?

    mutating func begin(_ generation: UUID) {
        current = generation
    }

    mutating func invalidate() {
        current = nil
    }

    @discardableResult
    mutating func finish(_ generation: UUID) -> Bool {
        guard current == generation else { return false }
        current = nil
        return true
    }
}

/// トースト通知を表示するオーバーレイコンポーネント
/// Requirements: 1.5, 3.3, 3.4, 5.3, 6.2
struct ToastOverlay: View {
    /// 表示するメッセージ（nilで非表示）
    let message: String?
    /// 同じ文言が連続しても別toastとしてTaskを入れ替えるidentity。
    var dismissalID: UUID = UUID()
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
        .task(id: dismissalID) {
            await scheduleAutoDismiss(generation: dismissalID)
        }
        .onChange(of: message) { _, newValue in
            if newValue == nil { dismissalGeneration.invalidate() }
        }
        .onDisappear {
            dismissalGeneration.invalidate()
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

    @State private var dismissalGeneration = ToastDismissalGeneration()

    @MainActor
    private func scheduleAutoDismiss(generation: UUID) async {
        guard message != nil else { return }
        dismissalGeneration.begin(generation)
        do {
            try await Task.sleep(for: .seconds(dismissDelay))
        } catch {
            return
        }
        guard !Task.isCancelled, dismissalGeneration.finish(generation) else { return }
        onDismiss()
    }
}

#Preview {
    ZStack {
        Color.black
        ToastOverlay(message: "スライドショー開始 3秒間隔") {}
    }
    .frame(width: 800, height: 600)
}
