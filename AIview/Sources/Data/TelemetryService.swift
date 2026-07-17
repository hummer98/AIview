import Foundation
import os

/// 匿名の利用計測 ping を送るサービス。
///
/// 設計方針（AIview のローカル完結・プライバシー重視の思想に配慮）:
/// - 送るのは **匿名 install UUID + アプリ版 / macOS版 / アーキ / ロケール** のみ。
///   ファイルパス・画像情報・ユーザー名など個人を特定しうる情報は一切送らない。
/// - 起動時に **日次デバウンス**で 1 回だけ fire-and-forget で GET する。
/// - `SettingsStore.analyticsEnabled`（既定 ON / opt-out）で無効化でき、
///   OFF の間は計測目的の通信を一切行わない。
/// - 送信先は Cloudflare Worker（`cloudflare/aiview-metrics/`）。集計は Worker 側の
///   `/stats` が返す。個々の ping はサーバに install 単位 1 行として集約される。
enum TelemetryService {
    /// 計測エンドポイント（Cloudflare Worker / D1）
    private static let endpoint = "https://aiview-metrics.rr-yamamoto.workers.dev/ping"

    private enum Keys {
        static let installID = "telemetryInstallID"
        static let lastPingDay = "telemetryLastPingDay"
    }

    /// 起動時に呼ぶ。`analyticsEnabled` が ON かつ本日未送信のときだけ ping する。
    /// - Note: fire-and-forget。失敗しても致命ではなく、翌アクティブ日に再試行される。
    static func pingIfNeeded(
        settings: SettingsStore = SettingsStore(),
        defaults: UserDefaults = .standard,
        session: URLSession = .shared
    ) {
        guard settings.analyticsEnabled else { return }

        let today = todayString()
        if defaults.string(forKey: Keys.lastPingDay) == today { return }

        let id = installID(defaults: defaults)
        guard let url = buildURL(installID: id) else { return }

        // 楽観的に「本日送信済み」を先にマークして、多重起動での重複送信を防ぐ。
        defaults.set(today, forKey: Keys.lastPingDay)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10

        let task = session.dataTask(with: request) { _, response, error in
            if let error {
                Logger.telemetry.debug("ping failed: \(error.localizedDescription, privacy: .public)")
            } else if let http = response as? HTTPURLResponse {
                Logger.telemetry.debug("ping status: \(http.statusCode, privacy: .public)")
            }
        }
        task.resume()
    }

    /// 匿名 install UUID（初回に生成して永続化）。個人情報とは無関係のランダム値。
    static func installID(defaults: UserDefaults = .standard) -> String {
        if let existing = defaults.string(forKey: Keys.installID) {
            return existing
        }
        let new = UUID().uuidString
        defaults.set(new, forKey: Keys.installID)
        return new
    }

    private static func buildURL(installID: String) -> URL? {
        var components = URLComponents(string: endpoint)
        components?.queryItems = [
            URLQueryItem(name: "id", value: installID),
            URLQueryItem(name: "v", value: appVersion),
            URLQueryItem(name: "os", value: osVersion),
            URLQueryItem(name: "arch", value: arch),
            URLQueryItem(name: "lang", value: locale),
        ]
        return components?.url
    }

    // MARK: - 匿名メタ情報

    static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
    }

    static var osVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var arch: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    static var locale: String {
        Locale.current.identifier
    }

    /// UTC の YYYY-MM-DD（日次デバウンスのキー）
    private static func todayString() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }
}
