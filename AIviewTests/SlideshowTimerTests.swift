import XCTest
import os
@testable import AIview

/// SlideshowTimer のTask ownershipを、実時間sleepなしで検証する。
@MainActor
final class SlideshowTimerTests: XCTestCase {
    func testInitialState_isNotRunning() {
        let (timer, _) = makeTimer()
        XCTAssertFalse(timer.isRunning)
        XCTAssertTrue(timer._debugTaskSnapshot().isIdle)
    }

    func testStart_callsOnTickAfterControlledInterval() async {
        let (timer, sleeper) = makeTimer()
        var tickCount = 0
        timer.start(interval: 1) { tickCount += 1 }

        await sleeper.waitForCallCount(1)
        sleeper.resumeCall(at: 0)
        await waitUntil { tickCount == 1 }

        XCTAssertTrue(timer.isRunning)
        timer.stop()
    }

    func testStart_callsOnTickMultipleTimes() async {
        let (timer, sleeper) = makeTimer()
        var tickCount = 0
        timer.start(interval: 1) { tickCount += 1 }

        await sleeper.waitForCallCount(1)
        sleeper.resumeCall(at: 0)
        await sleeper.waitForCallCount(2)
        sleeper.resumeCall(at: 1)
        await waitUntil { tickCount == 2 }

        timer.stop()
    }

    func testPause_cancelsPendingTickAndSetsNotRunning() async {
        let (timer, sleeper) = makeTimer()
        var tickCount = 0
        timer.start(interval: 1) { tickCount += 1 }
        await sleeper.waitForCallCount(1)

        timer.pause()
        await waitUntil { sleeper.pendingCount == 0 }

        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(tickCount, 0)
        XCTAssertTrue(timer._debugTaskSnapshot().isIdle)
    }

    func testResume_startsNewGeneration() async {
        let (timer, sleeper) = makeTimer()
        var tickCount = 0
        timer.start(interval: 1) { tickCount += 1 }
        await sleeper.waitForCallCount(1)
        let firstGeneration = timer._debugTaskSnapshot().generation

        timer.pause()
        timer.resume()
        await sleeper.waitForCallCount(2)
        let resumedGeneration = timer._debugTaskSnapshot().generation
        sleeper.resumeCall(at: 1)
        await waitUntil { tickCount == 1 }

        XCTAssertNotEqual(firstGeneration, resumedGeneration)
        XCTAssertTrue(timer.isRunning)
        timer.stop()
    }

    func testStop_cancelsPendingTickAndMakesSnapshotIdle() async {
        let (timer, sleeper) = makeTimer()
        var tickCount = 0
        timer.start(interval: 1) { tickCount += 1 }
        await sleeper.waitForCallCount(1)

        timer.stop()
        await waitUntil { sleeper.pendingCount == 0 }

        XCTAssertFalse(timer.isRunning)
        XCTAssertEqual(tickCount, 0)
        XCTAssertTrue(timer._debugTaskSnapshot().isIdle)
    }

    func testReset_replacesPendingGeneration() async {
        let (timer, sleeper) = makeTimer()
        var tickCount = 0
        timer.start(interval: 1) { tickCount += 1 }
        await sleeper.waitForCallCount(1)
        let firstGeneration = timer._debugTaskSnapshot().generation

        timer.reset()
        await sleeper.waitForCallCount(2)
        let resetGeneration = timer._debugTaskSnapshot().generation
        sleeper.resumeCall(at: 1)
        await waitUntil { tickCount == 1 }

        XCTAssertNotEqual(firstGeneration, resetGeneration)
        XCTAssertTrue(timer.isRunning)
        timer.stop()
    }

    func testUpdateInterval_restartsWithNewDuration() async {
        let (timer, sleeper) = makeTimer()
        timer.start(interval: 2) {}
        await sleeper.waitForCallCount(1)

        timer.updateInterval(1)
        await sleeper.waitForCallCount(2)

        XCTAssertEqual(sleeper.recordedDurations, [.seconds(2), .seconds(1)])
        timer.stop()
    }

    func testStart_cancelsPreviousGeneration() async {
        let (timer, sleeper) = makeTimer()
        var firstTimerCount = 0
        var secondTimerCount = 0
        timer.start(interval: 1) { firstTimerCount += 1 }
        await sleeper.waitForCallCount(1)

        timer.start(interval: 1) { secondTimerCount += 1 }
        await sleeper.waitForCallCount(2)
        sleeper.resumeCall(at: 1)
        await waitUntil { secondTimerCount == 1 }

        XCTAssertEqual(firstTimerCount, 0)
        timer.stop()
    }

    func testTimerTask_doesNotRetainOwnerAcrossSleep() async {
        let sleeper = ControlledSlideshowSleeper()
        weak var weakTimer: SlideshowTimer?
        var timer: SlideshowTimer? = SlideshowTimer { @Sendable duration in
            try await sleeper.sleep(for: duration)
        }
        weakTimer = timer
        timer?.start(interval: 60) {}
        await sleeper.waitForCallCount(1)
        XCTAssertEqual(timer?._debugTaskSnapshot().activeTasks, 1)
        timer = nil

        XCTAssertNil(weakTimer, "sleep 中のTaskがownerを保持してはならない")
        await waitUntil { sleeper.pendingCount == 0 }
    }

    private func makeTimer() -> (SlideshowTimer, ControlledSlideshowSleeper) {
        let sleeper = ControlledSlideshowSleeper()
        let timer = SlideshowTimer { @Sendable duration in
            try await sleeper.sleep(for: duration)
        }
        return (timer, sleeper)
    }

    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async {
        for _ in 0..<1_000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("controlled task did not reach the expected state")
    }
}

private final class ControlledSlideshowSleeper: Sendable {
    private struct State {
        var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
        var calls: [(id: UUID, duration: Duration)] = []
        var cancelledBeforeRegistration: Set<UUID> = []
        var countWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func sleep(for duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let registration = lock.withLock { state in
                    state.calls.append((id, duration))
                    let observers = state.countWaiters.filter { state.calls.count >= $0.count }
                    state.countWaiters.removeAll { state.calls.count >= $0.count }
                    if state.cancelledBeforeRegistration.remove(id) != nil {
                        return (cancelled: true, observers: observers)
                    }
                    state.pending[id] = continuation
                    return (cancelled: false, observers: observers)
                }
                registration.observers.forEach { $0.continuation.resume() }
                if registration.cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    func waitForCallCount(_ count: Int) async {
        let shouldWait = lock.withLock { state in state.calls.count < count }
        guard shouldWait else { return }
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock { state in
                guard state.calls.count < count else { return true }
                state.countWaiters.append((count, continuation))
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func resumeCall(at index: Int) {
        let continuation = lock.withLock { state -> CheckedContinuation<Void, Error>? in
            guard state.calls.indices.contains(index) else { return nil }
            return state.pending.removeValue(forKey: state.calls[index].id)
        }
        continuation?.resume()
    }

    var pendingCount: Int {
        lock.withLock { $0.pending.count }
    }

    var recordedDurations: [Duration] {
        lock.withLock { $0.calls.map(\.duration) }
    }

    private func cancel(id: UUID) {
        let continuation = lock.withLock { state -> CheckedContinuation<Void, Error>? in
            if let pending = state.pending.removeValue(forKey: id) { return pending }
            state.cancelledBeforeRegistration.insert(id)
            return nil
        }
        continuation?.resume(throwing: CancellationError())
    }
}
