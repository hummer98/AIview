import SwiftUI

/// プライバシーモードオーバーレイ
/// Requirements: 6.1-6.3
struct PrivacyOverlay: View {
    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 8) {
                Image(systemName: "eye.slash.fill")
                    .font(.system(size: 32))
                    .foregroundColor(.white.opacity(0.2))

                Text("プライバシーモード")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.2))

                Text("スペースキーで解除")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.15))
            }
        }
    }
}

#Preview {
    PrivacyOverlay()
        .frame(width: 600, height: 400)
}
