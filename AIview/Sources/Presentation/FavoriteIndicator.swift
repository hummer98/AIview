import SwiftUI

/// お気に入りレベルを星アイコンで視覚的に表示するコンポーネント
/// Requirements: 1.3
struct FavoriteIndicator: View {
    let level: Int
    let size: IndicatorSize

    enum IndicatorSize {
        case large   // メイン画像用
        case small   // サムネイル・ステータスバー用

        var starSize: CGFloat {
            switch self {
            case .large: return 24
            case .small: return 14
            }
        }

        var fontSize: CGFloat {
            switch self {
            case .large: return 16
            case .small: return 11
            }
        }

        var padding: CGFloat {
            switch self {
            case .large: return 8
            case .small: return 4
            }
        }
    }

    var body: some View {
        if level > 0 {
            HStack(spacing: 2) {
                Image(systemName: "star.fill")
                    .font(.system(size: size.starSize))
                    .foregroundColor(.yellow)
                Text("\(level)")
                    .font(.system(size: size.fontSize, weight: .bold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, size.padding)
            .padding(.vertical, size.padding / 2)
            .background(Color.black.opacity(0.6))
            .cornerRadius(size == .large ? 8 : 4)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ForEach(0...5, id: \.self) { level in
            HStack(spacing: 20) {
                FavoriteIndicator(level: level, size: .large)
                FavoriteIndicator(level: level, size: .small)
            }
        }
    }
    .padding()
    .background(Color.gray)
}
