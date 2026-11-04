import Foundation
import os

/// HTTP transport を注入可能にするための、Foundation の networking 型に依存しない request。
struct TelemetryRequest: Equatable, Sendable {
    let url: URL
    let method: String
    let headers: [String: String]
    let body: Data
    let timeoutInterval: TimeInterval
}

struct TelemetryResponse: Equatable, Sendable {
    let statusCode: Int
}

protocol TelemetryTransport: Sendable {
    func send(_ request: TelemetryRequest) async throws -> TelemetryResponse
}

struct URLSessionTelemetryTransport: TelemetryTransport {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: TelemetryRequest) async throws -> TelemetryResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        urlRequest.timeoutInterval = request.timeoutInterval
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (_, response) = try await session.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw TelemetryClientError.invalidResponse
        }
        return TelemetryResponse(statusCode: httpResponse.statusCode)
    }
}

protocol TelemetrySleeping: Sendable {
    func sleep(for duration: Duration) async throws
}

struct ContinuousTelemetrySleeper: TelemetrySleeping {
    func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

enum TelemetryClientError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case transportFailure
}

struct TelemetryConfiguration: Equatable, Sendable {
    let pingURL: URL
    let deleteURL: URL
    let maximumPingAttempts: Int
    let retryDelays: [Duration]
    let timeoutInterval: TimeInterval

    static let production = TelemetryConfiguration(
        pingURL: URL(string: "https://aiview-metrics.rr-yamamoto.workers.dev/v1/ping")!,
        deleteURL: URL(string: "https://aiview-metrics.rr-yamamoto.workers.dev/v1/delete")!,
        maximumPingAttempts: 3,
        retryDelays: [.seconds(1), .seconds(2)],
        timeoutInterval: 10
    )
}

struct TelemetryMetadata: Equatable, Sendable {
    let appVersion: String
    let osVersion: String
    let arch: String
    let locale: String

    static var current: TelemetryMetadata {
        TelemetryMetadata(
            appVersion: normalizedAppVersion(
                Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ),
            osVersion: normalizedOSVersion(ProcessInfo.processInfo.operatingSystemVersion),
            arch: normalizedArchitecture,
            locale: normalizedLocale(Locale.current)
        )
    }

    /// Worker の strict semver schema に合わせる。古い bundle 設定でも受理可能な値だけを送る。
    static func normalizedAppVersion(_ rawValue: String?) -> String {
        let value = rawValue ?? ""
        let pattern = #"^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"#
        if value.range(of: pattern, options: .regularExpression) != nil {
            return value
        }
        return "0.0.0"
    }

    private static func normalizedOSVersion(_ version: OperatingSystemVersion) -> String {
        let major = max(0, min(999, version.majorVersion))
        let minor = max(0, min(999, version.minorVersion))
        let patch = max(0, min(999, version.patchVersion))
        return "\(major).\(minor).\(patch)"
    }

    private static var normalizedArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        // 現在の macOS release target は arm64 / x86_64 のみ。未知 target の値は送らない。
        "x86_64"
        #endif
    }

    private static func normalizedLocale(_ locale: Locale) -> String {
        let language = locale.language.languageCode?.identifier
            .lowercased()
            .filter { $0.isASCII && $0.isLetter }
        let region = locale.region?.identifier
            .uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }

        guard let language, (2...3).contains(language.count) else { return "en-US" }
        if let region, (2...8).contains(region.count) {
            return "\(language)-\(region)"
        }
        return language
    }
}

private struct PingPayload: Encodable, Sendable {
    let installID: String
    let appVersion: String
    let osVersion: String
    let arch: String
    let locale: String

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
        case appVersion = "app_version"
        case osVersion = "os_version"
        case arch
        case locale
    }
}

private struct DeletePayload: Encodable, Sendable {
    let installID: String

    enum CodingKeys: String, CodingKey {
        case installID = "install_id"
    }
}

private enum TelemetryOperationOutcome: Sendable {
    case success
    case cancelled
    case failure(TelemetryClientError)
}

/// JSON POST、status 判定、bounded retry を担当する stateless client。
private struct TelemetryClient: Sendable {
    let transport: any TelemetryTransport
    let sleeper: any TelemetrySleeping
    let configuration: TelemetryConfiguration

    func ping(installID: String, metadata: TelemetryMetadata) async -> TelemetryOperationOutcome {
        let payload = PingPayload(
            installID: installID,
            appVersion: metadata.appVersion,
            osVersion: metadata.osVersion,
            arch: metadata.arch,
            locale: metadata.locale
        )
        guard let request = makeRequest(url: configuration.pingURL, payload: payload) else {
            return .failure(.invalidResponse)
        }

        let attempts = max(1, configuration.maximumPingAttempts)
        for attempt in 0..<attempts {
            do {
                try Task.checkCancellation()
                let response = try await transport.send(request)
                try Task.checkCancellation()

                if (200...299).contains(response.statusCode) {
                    return .success
                }

                let error = TelemetryClientError.httpStatus(response.statusCode)
                guard shouldRetry(statusCode: response.statusCode), attempt + 1 < attempts else {
                    return .failure(error)
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                guard attempt + 1 < attempts else {
                    return .failure(.transportFailure)
                }
            }

            do {
                let delay = configuration.retryDelays.indices.contains(attempt)
                    ? configuration.retryDelays[attempt]
                    : configuration.retryDelays.last ?? .zero
                try await sleeper.sleep(for: delay)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failure(.transportFailure)
            }
        }
        return .failure(.transportFailure)
    }

    func delete(installID: String) async -> TelemetryOperationOutcome {
        guard let request = makeRequest(
            url: configuration.deleteURL,
            payload: DeletePayload(installID: installID)
        ) else {
            return .failure(.invalidResponse)
        }

        do {
            try Task.checkCancellation()
            let response = try await transport.send(request)
            try Task.checkCancellation()
            guard (200...299).contains(response.statusCode) else {
                return .failure(.httpStatus(response.statusCode))
            }
            return .success
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failure(.transportFailure)
        }
    }

    private func makeRequest<Payload: Encodable>(
        url: URL,
        payload: Payload
    ) -> TelemetryRequest? {
        guard url.scheme == "https", url.query == nil, let body = try? JSONEncoder().encode(payload) else {
            return nil
        }
        return TelemetryRequest(
            url: url,
            method: "POST",
            headers: [
                "Accept": "application/json",
                "Content-Type": "application/json",
            ],
            body: body,
            timeoutInterval: configuration.timeoutInterval
        )
    }

    private func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 425 || statusCode == 429 || statusCode >= 500
    }
}

/// process-global な telemetry state と、唯一の in-flight/retry Task を所有する。
///
/// Window の `onAppear` が複数回来ても起動中の bounded attempt は一度だけ。成功 marker は
/// 2xx response を受信した後だけ記録し、失敗後は次回 launch まで再送しない。
@MainActor
@Observable
final class TelemetryCoordinator {
    private enum Keys {
        static let installID = "telemetryInstallID"
        static let lastPingDay = "telemetryLastPingDay"
    }

    private let settings: SettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let client: TelemetryClient
    @ObservationIgnored private let metadata: TelemetryMetadata
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored private let makeUUID: @Sendable () -> UUID

    @ObservationIgnored private var operationTask: Task<Void, Never>?
    @ObservationIgnored private var operationGeneration: UUID?
    @ObservationIgnored private var didAttemptPingThisLaunch = false

    private(set) var isResettingIdentifier = false
    private(set) var resetError: AppError?

    var analyticsEnabled: Bool {
        settings.analyticsEnabled
    }

    init(
        settings: SettingsStore,
        defaults: UserDefaults = .standard,
        transport: any TelemetryTransport = URLSessionTelemetryTransport(),
        sleeper: any TelemetrySleeping = ContinuousTelemetrySleeper(),
        configuration: TelemetryConfiguration = .production,
        metadata: TelemetryMetadata = .current,
        clock: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() }
    ) {
        self.settings = settings
        self.defaults = defaults
        client = TelemetryClient(
            transport: transport,
            sleeper: sleeper,
            configuration: configuration
        )
        self.metadata = metadata
        self.clock = clock
        self.makeUUID = makeUUID
    }

    deinit {
        operationTask?.cancel()
    }

    /// WindowGroup の appear 回数に関係なく、一 launch につき最大一系列だけ開始する。
    func pingIfNeeded() {
        guard analyticsEnabled,
              !didAttemptPingThisLaunch,
              operationTask == nil
        else { return }

        let day = Self.utcDay(from: clock())
        guard defaults.string(forKey: Keys.lastPingDay) != day else {
            didAttemptPingThisLaunch = true
            return
        }

        didAttemptPingThisLaunch = true
        let installID = validatedInstallID()
        let generation = UUID()
        operationGeneration = generation
        let client = client
        let metadata = metadata

        operationTask = Task { [weak self] in
            let outcome = await client.ping(installID: installID, metadata: metadata)
            self?.finishPing(outcome, day: day, generation: generation)
        }
    }

    /// 設定変更を coordinator に集約し、OFF では transport / retry sleep を即 cancel する。
    func setAnalyticsEnabled(_ enabled: Bool) {
        let wasEnabled = settings.analyticsEnabled
        settings.analyticsEnabled = enabled

        guard enabled else {
            operationTask?.cancel()
            return
        }

        if !wasEnabled {
            didAttemptPingThisLaunch = false
        }
        pingIfNeeded()
    }

    /// Server 上の旧 UUID を消してからだけ、local UUID と送信 marker を更新する。
    /// 明示的な privacy 操作なので analytics OFF 中でも実行できる。
    func resetAnonymousIdentifier() {
        guard !isResettingIdentifier else { return }

        resetError = nil
        isResettingIdentifier = true
        guard let oldInstallID = defaults.string(forKey: Keys.installID),
              Self.isUUIDv4(oldInstallID)
        else {
            resetError = .unknown(.deleteTelemetryIdentifier)
            isResettingIdentifier = false
            return
        }
        let previousTask = operationTask
        previousTask?.cancel()

        let generation = UUID()
        operationGeneration = generation
        let client = client

        operationTask = Task { [weak self] in
            if let previousTask {
                await previousTask.value
            }
            guard !Task.isCancelled else {
                self?.finishReset(.cancelled, oldInstallID: oldInstallID, generation: generation)
                return
            }

            let outcome = await client.delete(installID: oldInstallID)
            self?.finishReset(outcome, oldInstallID: oldInstallID, generation: generation)
        }
    }

    func dismissResetError() {
        resetError = nil
    }

    private func finishPing(
        _ outcome: TelemetryOperationOutcome,
        day: String,
        generation: UUID
    ) {
        guard operationGeneration == generation else { return }
        defer { clearOperation(generation: generation) }

        switch outcome {
        case .success where analyticsEnabled:
            defaults.set(day, forKey: Keys.lastPingDay)
            Logger.telemetry.debug("Telemetry ping completed")
        case .success, .cancelled:
            break
        case .failure(let error):
            logFailure(error, event: "Telemetry ping failed")
        }
    }

    private func finishReset(
        _ outcome: TelemetryOperationOutcome,
        oldInstallID: String,
        generation: UUID
    ) {
        guard operationGeneration == generation else { return }
        defer {
            isResettingIdentifier = false
            clearOperation(generation: generation)
        }

        switch outcome {
        case .success:
            // delete中に別 code path がIDを書き換えていた場合は上書きしない。
            guard defaults.string(forKey: Keys.installID) == oldInstallID else {
                assertionFailure("Telemetry install ID changed during reset")
                resetError = .invariant(.deleteTelemetryIdentifier)
                return
            }
            defaults.removeObject(forKey: Keys.lastPingDay)
            defaults.set(makeUUID().uuidString, forKey: Keys.installID)
            // reset自身をping triggerにせず、次のlaunch/明示的な有効化まで待つ。
            didAttemptPingThisLaunch = true
            Logger.telemetry.info("Anonymous telemetry identifier reset")
        case .cancelled:
            break
        case .failure(let error):
            resetError = AppError.classify(error, operation: .deleteTelemetryIdentifier)
            logFailure(error, event: "Telemetry identifier reset failed")
        }
    }

    private func clearOperation(generation: UUID) {
        guard operationGeneration == generation else { return }
        operationTask = nil
        operationGeneration = nil
    }

    private func validatedInstallID() -> String {
        if let existing = defaults.string(forKey: Keys.installID), Self.isUUIDv4(existing) {
            return existing
        }
        let newID = makeUUID().uuidString
        defaults.set(newID, forKey: Keys.installID)
        defaults.removeObject(forKey: Keys.lastPingDay)
        return newID
    }

    private func logFailure(_ error: TelemetryClientError, event: StaticString) {
        switch error {
        case .httpStatus(let statusCode):
            Logger.telemetry.warning("\(event): status=\(statusCode, privacy: .public)")
        case .invalidResponse:
            Logger.telemetry.warning("\(event): invalid_response")
        case .transportFailure:
            Logger.telemetry.warning("\(event): transport_failure")
        }
    }

    private static func isUUIDv4(_ value: String) -> Bool {
        let pattern = #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-4[0-9A-Fa-f]{3}-[89ABab][0-9A-Fa-f]{3}-[0-9A-Fa-f]{12}$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }

    private static func utcDay(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

#if DEBUG
    func _debugWaitForCurrentOperation() async {
        let task = operationTask
        await task?.value
    }

    var _debugActiveOperationCount: Int {
        operationGeneration == nil ? 0 : 1
    }
#endif
}
