import SwiftUI

/// 設定ウィンドウのビュー
struct SettingsView: View {
    private let settingsStore = SettingsStore()

    @State private var fullImageCacheSizeMB: Double
    @State private var thumbnailCacheSizeMB: Double

    init() {
        let store = SettingsStore()
        _fullImageCacheSizeMB = State(initialValue: Double(store.fullImageCacheSizeMB))
        _thumbnailCacheSizeMB = State(initialValue: Double(store.thumbnailCacheSizeMB))
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    CacheSlider(
                        title: "フルサイズ画像キャッシュ",
                        value: $fullImageCacheSizeMB,
                        range: 128...4096,
                        step: 128,
                        description: "表示用のフルサイズ画像をメモリにキャッシュする容量"
                    )

                    Divider()

                    CacheSlider(
                        title: "サムネイルキャッシュ",
                        value: $thumbnailCacheSizeMB,
                        range: 64...2048,
                        step: 64,
                        description: "カルーセル表示用のサムネイル画像をメモリにキャッシュする容量"
                    )
                }
            } header: {
                Text("メモリキャッシュ")
            } footer: {
                Text("キャッシュサイズを大きくすると、より多くの画像をメモリに保持できますが、システムメモリを消費します。変更は次回起動時に反映されます。")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 280)
        .onDisappear {
            saveSettings()
        }
    }

    private func saveSettings() {
        var store = settingsStore
        store.fullImageCacheSizeMB = Int(fullImageCacheSizeMB)
        store.thumbnailCacheSizeMB = Int(thumbnailCacheSizeMB)
    }
}

/// キャッシュサイズ設定用スライダー
private struct CacheSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                    .fontWeight(.medium)
                Spacer()
                Text("\(Int(value)) MB")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Slider(value: $value, in: range, step: step)

            HStack {
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    SettingsView()
}
