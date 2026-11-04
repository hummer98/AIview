import SwiftUI

/// 設定ウィンドウのビュー
/// TabView で表示設定とキャッシュ設定を提供する。
/// window-local metrics は focused window の「開発」メニューから取得する。
struct SettingsView: View {
    let appServices: AppServices

    var body: some View {
        TabView {
            DisplaySettingsTab(appServices: appServices)
                .tabItem {
                    Label("表示", systemImage: "photo")
                }

            CacheSettingsTab()
                .tabItem {
                    Label("キャッシュ", systemImage: "memorychip")
                }

        }
        .frame(width: 520, height: 480)
    }
}

// MARK: - Display Settings Tab

private struct DisplaySettingsTab: View {
    let appServices: AppServices

    @State private var restoreLastViewedConfirmEnabled: Bool
    @State private var analyticsEnabled: Bool

    init(appServices: AppServices) {
        self.appServices = appServices
        let store = appServices.settingsStore
        _restoreLastViewedConfirmEnabled = State(initialValue: store.restoreLastViewedConfirmEnabled)
        _analyticsEnabled = State(initialValue: store.analyticsEnabled)
    }

    var body: some View {
        Form {
            Section {
                Toggle(
                    "フォルダを開いたとき前回の表示位置を確認する",
                    isOn: $restoreLastViewedConfirmEnabled
                )
                .onChange(of: restoreLastViewedConfirmEnabled) { _, newValue in
                    appServices.settingsStore.restoreLastViewedConfirmEnabled = newValue
                }
            } header: {
                Text("前回の表示位置")
            } footer: {
                Text("ON にすると、記録がある場合にフォルダを開いた直後へ移動確認ダイアログを表示します。記録はこの設定に関わらず行われます（プライバシーモード中を除く）。")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Toggle(
                    "匿名の利用統計を送信する",
                    isOn: $analyticsEnabled
                )
                .onChange(of: analyticsEnabled) { _, newValue in
                    appServices.telemetryCoordinator.setAnalyticsEnabled(newValue)
                }

                Button("仮名IDをサーバーから削除してリセット", role: .destructive) {
                    appServices.telemetryCoordinator.resetAnonymousIdentifier()
                }
                .disabled(appServices.telemetryCoordinator.isResettingIdentifier)

                if appServices.telemetryCoordinator.isResettingIdentifier {
                    ProgressView("仮名IDを削除しています…")
                }
            } header: {
                Text("プライバシー")
            } footer: {
                Text("開発の参考にするため、起動時に利用統計を1日1回送信します。送信内容は推測困難な仮名ID、アプリとmacOSのバージョン、CPU種別、言語設定です。サーバーはこれらに国コード、初回/最終送信時刻、利用日数を加えてinstallごとに1行保存し、最終送信から400日後に削除します。OFF中は通常の統計通信を行いません。仮名IDの明示的な削除だけはOFF中でも実行できます。")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .alert(
            appServices.telemetryCoordinator.resetError?.presentation?.title ?? "仮名IDを削除できませんでした",
            isPresented: Binding(
                get: { appServices.telemetryCoordinator.resetError?.presentation != nil },
                set: { isPresented in
                    if !isPresented {
                        appServices.telemetryCoordinator.dismissResetError()
                    }
                }
            )
        ) {
            Button("再試行") {
                appServices.telemetryCoordinator.resetAnonymousIdentifier()
            }
            Button("キャンセル", role: .cancel) {
                appServices.telemetryCoordinator.dismissResetError()
            }
        } message: {
            Text(
                appServices.telemetryCoordinator.resetError?.presentation?.message
                    ?? "通信状態を確認して、もう一度お試しください。"
            )
        }
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
        let store = settingsStore
        store.fullImageCacheSizeMB = Int(fullImageCacheSizeMB)
        store.thumbnailCacheSizeMB = Int(thumbnailCacheSizeMB)
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
    SettingsView(appServices: AppServices())
}
