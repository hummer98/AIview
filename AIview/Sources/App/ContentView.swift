import SwiftUI

/// メインコンテンツビュー
/// MainWindowViewをラップ
@MainActor
struct ContentView: View {
    @State private var session: BrowserWindowSession

    init(appServices: AppServices) {
        let environment = ProcessInfo.processInfo.environment
        let isUITestMode = environment["AIVIEW_UI_TEST_MODE"] == "1"
        let backgroundImageWorkEnabled = !isUITestMode
            || environment["AIVIEW_UI_TEST_BACKGROUND_IMAGE_WORK"] != "0"
        let viewModel = ImageBrowserViewModel(
            recentFoldersStore: appServices.recentFoldersStore,
            backgroundImageWorkEnabled: backgroundImageWorkEnabled
        )
        _session = State(
            initialValue: BrowserWindowSession(appServices: appServices, viewModel: viewModel)
        )
    }

    var body: some View {
        MainWindowView(session: session)
    }
}

#Preview {
    ContentView(appServices: AppServices())
}
