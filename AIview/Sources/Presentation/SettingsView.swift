import SwiftUI

/// 設定ウィンドウのビュー
/// TabView でキャッシュ設定と診断情報の2タブを提供
struct SettingsView: View {
    var body: some View {
        TabView {
            CacheSettingsTab()
                .tabItem {
                    Label("キャッシュ", systemImage: "memorychip")
                }

            DiagnosticsTab()
                .tabItem {
                    Label("診断情報", systemImage: "chart.bar.xaxis")
                }
        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - Cache Settings Tab

private struct CacheSettingsTab: View {
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

// MARK: - Diagnostics Tab

private struct DiagnosticsTab: View {
    @Environment(AppState.self) private var appState: AppState?
    @State private var snapshot: MetricsSnapshot?
    @State private var isLoading = false
    @State private var copyFeedback: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("更新", systemImage: "arrow.clockwise")
                }
                .disabled(isLoading)

                Button {
                    copyJSONToPasteboard()
                } label: {
                    Label("JSON をコピー", systemImage: "doc.on.doc")
                }
                .disabled(snapshot == nil)

                if let feedback = copyFeedback {
                    Text(feedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            ScrollView {
                if let snapshot {
                    Text(snapshot.formattedLogString())
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(6)
                } else {
                    Text(isLoading ? "読み込み中..." : "「更新」を押して最新の診断情報を表示")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(16)
        .task {
            if snapshot == nil {
                await refresh()
            }
        }
    }

    private func refresh() async {
        guard let appState else { return }
        isLoading = true
        let new = await appState.metricsCollector.snapshot()
        snapshot = new
        isLoading = false
    }

    private func copyJSONToPasteboard() {
        guard let snapshot else { return }
        let json = snapshot.toJSONString()
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(json, forType: .string)
        copyFeedback = "コピーしました"
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copyFeedback = nil
        }
    }
}

// MARK: - Cache Slider

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
