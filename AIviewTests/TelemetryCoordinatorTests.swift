import Foundation
import XCTest
@testable import AIview

@MainActor
final class TelemetryCoordinatorTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var settings: SettingsStore!

    private let oldID = "11111111-1111-4111-8111-111111111111"
    private let newID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let fixedDate = Date(timeIntervalSince1970: 1_786_406_400) // 2026-08-11 UTC

    override func setUp() async throws {
        suiteName = "TelemetryCoordinatorTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        settings = SettingsStore(defaults: defaults)
        defaults.set(oldID, forKey: "telemetryInstallID")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        settings = nil
        defaults = nil
        suiteName = nil
    }

    func testPingUsesQuerylessJSONPostAndMarksOnlyAfter2xx() async throws {
        let transport = TelemetryTestTransport(results: [.success(204)])
        let coordinator = makeCoordinator(transport: transport)

        coordinator.pingIfNeeded()
        await coordinator._debugWaitForCurrentOperation()

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.path, "/v1/ping")
        XCTAssertNil(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.query)
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Accept"], "application/json")

        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: String]
        )
        XCTAssertEqual(json, [
            "install_id": oldID,
            "app_version": "1.2.3",
            "os_version": "15.6.0",
            "arch": "arm64",
            "locale": "ja-JP",
        ])
        XCTAssertEqual(defaults.string(forKey: "telemetryLastPingDay"), "2026-08-11")
        XCTAssertEqual(coordinator._debugActiveOperationCount, 0)
    }

    func testNon2xxRetriesAreBoundedAndDoNotWriteMarker() async {
        let transport = TelemetryTestTransport(results: [
            .success(503), .success(503), .success(503),
        ])
        let sleeper = RecordingTelemetrySleeper()
        let coordinator = makeCoordinator(transport: transport, sleeper: sleeper)

        coordinator.pingIfNeeded()
        await coordinator._debugWaitForCurrentOperation()
        coordinator.pingIfNeeded()

        let requestCount = await transport.requestCount()
        let sleepCount = await sleeper.recordedCount()
        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(sleepCount, 2)
        XCTAssertNil(defaults.string(forKey: "telemetryLastPingDay"))
        XCTAssertEqual(coordinator._debugActiveOperationCount, 0)
    }

    func testTransportFailureDoesNotWriteMarker() async {
        let transport = TelemetryTestTransport(results: [
            .failure(.offline), .failure(.offline), .failure(.offline),
        ])
        let coordinator = makeCoordinator(transport: transport)

        coordinator.pingIfNeeded()
        await coordinator._debugWaitForCurrentOperation()

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 3)
        XCTAssertNil(defaults.string(forKey: "telemetryLastPingDay"))
    }

    func testMultipleWindowStartsShareOneInFlightRequest() async {
        let transport = TelemetryTestTransport(results: [.success(204)], holdsFirstRequest: true)
        let coordinator = makeCoordinator(transport: transport)

        coordinator.pingIfNeeded()
        coordinator.pingIfNeeded()
        coordinator.pingIfNeeded()
        await transport.waitForRequestCount(1)

        let requestCountWhileHeld = await transport.requestCount()
        XCTAssertEqual(requestCountWhileHeld, 1)
        XCTAssertEqual(coordinator._debugActiveOperationCount, 1)
        XCTAssertNil(defaults.string(forKey: "telemetryLastPingDay"))

        await transport.releaseHeldRequest()
        await coordinator._debugWaitForCurrentOperation()
        let finalRequestCount = await transport.requestCount()
        XCTAssertEqual(finalRequestCount, 1)
        XCTAssertEqual(coordinator._debugActiveOperationCount, 0)
    }

    func testTurningAnalyticsOffCancelsRetrySleepAndPreventsFurtherRequests() async {
        let transport = TelemetryTestTransport(results: [.success(503), .success(204)])
        let sleeper = ControlledTelemetrySleeper()
        let coordinator = makeCoordinator(transport: transport, sleeper: sleeper)

        coordinator.pingIfNeeded()
        await sleeper.waitUntilSleeping()
        coordinator.setAnalyticsEnabled(false)
        await coordinator._debugWaitForCurrentOperation()
        coordinator.pingIfNeeded()

        XCTAssertFalse(settings.analyticsEnabled)
        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(defaults.string(forKey: "telemetryLastPingDay"))
        XCTAssertEqual(coordinator._debugActiveOperationCount, 0)
    }

    func testTurningAnalyticsOffCancelsInFlightTransportAndLeavesOwnerIdle() async {
        let transport = TelemetryTestTransport(results: [.success(204)], holdsFirstRequest: true)
        let coordinator = makeCoordinator(transport: transport)

        coordinator.pingIfNeeded()
        await transport.waitForRequestCount(1)
        coordinator.setAnalyticsEnabled(false)
        await coordinator._debugWaitForCurrentOperation()
        coordinator.pingIfNeeded()

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 1)
        XCTAssertNil(defaults.string(forKey: "telemetryLastPingDay"))
        XCTAssertEqual(coordinator._debugActiveOperationCount, 0)
    }

    func testOptOutMakesNoRoutineRequest() async {
        settings.analyticsEnabled = false
        let transport = TelemetryTestTransport(results: [.success(204)])
        let coordinator = makeCoordinator(transport: transport)

        coordinator.pingIfNeeded()
        await coordinator._debugWaitForCurrentOperation()

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertNil(defaults.string(forKey: "telemetryLastPingDay"))
    }

    func testSuccessfulDeleteKeepsOldIDInRequestThenCreatesNewIDAndClearsMarker() async throws {
        settings.analyticsEnabled = false
        defaults.set("2026-08-11", forKey: "telemetryLastPingDay")
        let transport = TelemetryTestTransport(results: [.success(204)])
        let coordinator = makeCoordinator(transport: transport)

        coordinator.resetAnonymousIdentifier()
        await coordinator._debugWaitForCurrentOperation()

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url.path, "/v1/delete")
        XCTAssertNil(request.url.query)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: String]
        )
        XCTAssertEqual(json["install_id"], oldID)
        XCTAssertEqual(defaults.string(forKey: "telemetryInstallID"), newID.uuidString)
        XCTAssertNil(defaults.string(forKey: "telemetryLastPingDay"))
        XCTAssertNil(coordinator.resetError)
        XCTAssertFalse(coordinator.isResettingIdentifier)
    }

    func testFailedDeletePreservesOldIDAndOffersRecoverableError() async {
        settings.analyticsEnabled = false
        defaults.set("2026-08-11", forKey: "telemetryLastPingDay")
        let transport = TelemetryTestTransport(results: [.success(503)])
        let coordinator = makeCoordinator(transport: transport)

        coordinator.resetAnonymousIdentifier()
        await coordinator._debugWaitForCurrentOperation()

        XCTAssertEqual(defaults.string(forKey: "telemetryInstallID"), oldID)
        XCTAssertEqual(defaults.string(forKey: "telemetryLastPingDay"), "2026-08-11")
        XCTAssertNotNil(coordinator.resetError?.presentation)
        XCTAssertFalse(coordinator.isResettingIdentifier)
        XCTAssertEqual(coordinator._debugActiveOperationCount, 0)
    }

    func testDeleteWaitsForCancelledPingAndDoesNotAutomaticallyPingNewID() async throws {
        let transport = TelemetryTestTransport(
            results: [.success(204), .success(204)],
            holdsFirstRequest: true
        )
        let coordinator = makeCoordinator(transport: transport)

        coordinator.pingIfNeeded()
        await transport.waitForRequestCount(1)
        coordinator.resetAnonymousIdentifier()
        await transport.waitForRequestCount(2)
        await coordinator._debugWaitForCurrentOperation()

        let requests = await transport.requests()
        XCTAssertEqual(requests.map(\.url.path), ["/v1/ping", "/v1/delete"])
        let deleteJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: requests[1].body) as? [String: String]
        )
        XCTAssertEqual(deleteJSON["install_id"], oldID)
        let maximumConcurrentRequestCount = await transport.maximumConcurrentRequestCount()
        let requestCount = await transport.requestCount()
        XCTAssertEqual(maximumConcurrentRequestCount, 1)
        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(defaults.string(forKey: "telemetryInstallID"), newID.uuidString)
    }

    func testInvalidPersistedIdentifierIsReplacedByUUIDv4BeforeSending() async throws {
        defaults.set("predictable-install-id", forKey: "telemetryInstallID")
        let transport = TelemetryTestTransport(results: [.success(204)])
        let coordinator = makeCoordinator(transport: transport)

        coordinator.pingIfNeeded()
        await coordinator._debugWaitForCurrentOperation()

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: request.body) as? [String: String]
        )
        XCTAssertEqual(json["install_id"], newID.uuidString)
        XCTAssertEqual(defaults.string(forKey: "telemetryInstallID"), newID.uuidString)
    }

    func testInvalidPersistedIdentifierIsNotChangedWhenResetCannotStart() async {
        defaults.set("predictable-install-id", forKey: "telemetryInstallID")
        defaults.set("2026-08-10", forKey: "telemetryLastPingDay")
        let transport = TelemetryTestTransport(results: [.success(204)])
        let coordinator = makeCoordinator(transport: transport)

        coordinator.resetAnonymousIdentifier()
        await coordinator._debugWaitForCurrentOperation()

        let requestCount = await transport.requestCount()
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(defaults.string(forKey: "telemetryInstallID"), "predictable-install-id")
        XCTAssertEqual(defaults.string(forKey: "telemetryLastPingDay"), "2026-08-10")
        XCTAssertNotNil(coordinator.resetError?.presentation)
    }

    func testAppVersionNormalizationMatchesServerStrictSemver() {
        XCTAssertEqual(TelemetryMetadata.normalizedAppVersion("1.2.3"), "1.2.3")
        XCTAssertEqual(TelemetryMetadata.normalizedAppVersion("1.2.3-beta.1+build.7"), "1.2.3-beta.1+build.7")
        XCTAssertEqual(TelemetryMetadata.normalizedAppVersion("1.2.3-01"), "0.0.0")
        XCTAssertEqual(TelemetryMetadata.normalizedAppVersion("1.2.3-beta..1"), "0.0.0")
        XCTAssertEqual(TelemetryMetadata.normalizedAppVersion("1.2"), "0.0.0")
        XCTAssertEqual(TelemetryMetadata.normalizedAppVersion(nil), "0.0.0")
    }

    private func makeCoordinator(
        transport: any TelemetryTransport,
        sleeper: any TelemetrySleeping = RecordingTelemetrySleeper()
    ) -> TelemetryCoordinator {
        let fixedDate = fixedDate
        let newID = newID
        return TelemetryCoordinator(
            settings: settings,
            defaults: defaults,
            transport: transport,
            sleeper: sleeper,
            configuration: TelemetryConfiguration(
                pingURL: URL(string: "https://telemetry.example/v1/ping")!,
                deleteURL: URL(string: "https://telemetry.example/v1/delete")!,
                maximumPingAttempts: 3,
                retryDelays: [.seconds(1), .seconds(2)],
                timeoutInterval: 10
            ),
            metadata: TelemetryMetadata(
                appVersion: "1.2.3",
                osVersion: "15.6.0",
                arch: "arm64",
                locale: "ja-JP"
            ),
            clock: { fixedDate },
            makeUUID: { newID }
        )
    }
}

private enum TelemetryTestTransportError: Error {
    case offline
}

private actor TelemetryTestTransport: TelemetryTransport {
    private var results: [Result<Int, TelemetryTestTransportError>]
    private var recordedRequests: [TelemetryRequest] = []
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var heldContinuation: CheckedContinuation<Void, Error>?
    private let holdsFirstRequest: Bool
    private var concurrentRequests = 0
    private var maximumConcurrentRequests = 0

    init(
        results: [Result<Int, TelemetryTestTransportError>],
        holdsFirstRequest: Bool = false
    ) {
        self.results = results
        self.holdsFirstRequest = holdsFirstRequest
    }

    func send(_ request: TelemetryRequest) async throws -> TelemetryResponse {
        recordedRequests.append(request)
        concurrentRequests += 1
        maximumConcurrentRequests = max(maximumConcurrentRequests, concurrentRequests)
        notifyRequestWaiters()
        defer { concurrentRequests -= 1 }

        if holdsFirstRequest, recordedRequests.count == 1 {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    heldContinuation = continuation
                }
            } onCancel: {
                Task { await self.cancelHeldRequest() }
            }
        }
        try Task.checkCancellation()

        guard !results.isEmpty else {
            throw TelemetryTestTransportError.offline
        }
        switch results.removeFirst() {
        case .success(let statusCode):
            return TelemetryResponse(statusCode: statusCode)
        case .failure(let error):
            throw error
        }
    }

    func requests() -> [TelemetryRequest] {
        recordedRequests
    }

    func requestCount() -> Int {
        recordedRequests.count
    }

    func maximumConcurrentRequestCount() -> Int {
        maximumConcurrentRequests
    }

    func waitForRequestCount(_ count: Int) async {
        guard recordedRequests.count < count else { return }
        await withCheckedContinuation { continuation in
            requestWaiters.append((count, continuation))
        }
    }

    func releaseHeldRequest() {
        heldContinuation?.resume()
        heldContinuation = nil
    }

    private func cancelHeldRequest() {
        heldContinuation?.resume(throwing: CancellationError())
        heldContinuation = nil
    }

    private func notifyRequestWaiters() {
        var pending: [(Int, CheckedContinuation<Void, Never>)] = []
        for (count, continuation) in requestWaiters {
            if recordedRequests.count >= count {
                continuation.resume()
            } else {
                pending.append((count, continuation))
            }
        }
        requestWaiters = pending
    }
}

private actor RecordingTelemetrySleeper: TelemetrySleeping {
    private var durations: [Duration] = []

    func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        durations.append(duration)
    }

    func recordedCount() -> Int {
        durations.count
    }
}

private actor ControlledTelemetrySleeper: TelemetrySleeping {
    private var sleepContinuation: CheckedContinuation<Void, Error>?
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var isSleeping = false

    func sleep(for _: Duration) async throws {
        isSleeping = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        waiters.forEach { $0.resume() }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepContinuation = continuation
            }
        } onCancel: {
            Task { await self.cancelSleep() }
        }
    }

    func waitUntilSleeping() async {
        guard !isSleeping else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append(continuation)
        }
    }

    private func cancelSleep() {
        sleepContinuation?.resume(throwing: CancellationError())
        sleepContinuation = nil
        isSleeping = false
    }
}
