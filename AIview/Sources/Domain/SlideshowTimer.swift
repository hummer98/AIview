import Foundation
import os

private final class SlideshowTaskOwner: Sendable {
    struct Snapshot: Equatable, Sendable {
        let activeTasks: Int
        let generation: UUID?
    }

    private struct State {
        var task: Task<Void, Never>?
        var generation: UUID?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func begin() -> UUID {
        cancel()
        return lock.withLock { state in
            let generation = UUID()
            state.generation = generation
            return generation
        }
    }

    func install(_ task: Task<Void, Never>, generation: UUID) {
        let accepted = lock.withLock { state in
            guard state.generation == generation else { return false }
            state.task = task
            return true
        }
        if !accepted { task.cancel() }
    }

    func finish(generation: UUID) {
        lock.withLock { state in
            guard state.generation == generation else { return }
            state.task = nil
            state.generation = nil
        }
    }

    func cancel() {
        let task = lock.withLock { state in
            let task = state.task
            state.task = nil
            state.generation = nil
            return task
        }
        task?.cancel()
    }

    func snapshot() -> Snapshot {
        lock.withLock { state in
            Snapshot(activeTasks: state.generation == nil ? 0 : 1, generation: state.generation)
        }
    }

    deinit {
        cancel()
    }
}

/// スライドショーの自動進行タイマー管理
/// Requirements: 2.1, 4.1, 4.2, 6.3
@MainActor
final class SlideshowTimer {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    struct TaskSnapshot: Equatable, Sendable {
        let activeTasks: Int
        let generation: UUID?

        var isIdle: Bool { activeTasks == 0 && generation == nil }
    }

    // MARK: - Properties

    private let taskOwner = SlideshowTaskOwner()
    private var isPaused: Bool = false
    private var currentInterval: Int = 3
    private var onTickHandler: (@MainActor () async -> Void)?
    private let sleeper: Sleeper

    /// タイマーが実行中かどうか
    var isRunning: Bool {
        taskOwner.snapshot().activeTasks > 0 && !isPaused
    }

    init(sleeper: Sleeper? = nil) {
        self.sleeper = sleeper ?? { @Sendable duration in
            try await Task.sleep(for: duration)
        }
    }

    deinit {
        taskOwner.cancel()
    }

    // MARK: - Public Methods

    /// タイマーを開始
    /// - Parameters:
    ///   - interval: 間隔（秒）1-60の範囲
    ///   - onTick: 間隔ごとに呼ばれるコールバック
    func start(interval: Int, onTick: @escaping @MainActor () async -> Void) {
        // 既存のタイマーをキャンセル
        stop()

        let clampedInterval = max(1, min(60, interval))
        currentInterval = clampedInterval
        onTickHandler = onTick
        isPaused = false

        startTimerLoop()

        Logger.slideshow.info("Slideshow timer started: interval=\(clampedInterval, privacy: .public)s")
    }

    /// タイマーを一時停止
    func pause() {
        isPaused = true
        taskOwner.cancel()

        Logger.slideshow.debug("Slideshow timer paused")
    }

    /// タイマーを再開
    func resume() {
        guard isPaused, onTickHandler != nil else { return }

        isPaused = false
        startTimerLoop()

        Logger.slideshow.debug("Slideshow timer resumed")
    }

    /// タイマーを停止
    func stop() {
        taskOwner.cancel()
        isPaused = false
        onTickHandler = nil

        Logger.slideshow.info("Slideshow timer stopped")
    }

    /// タイマーをリセット（現在の待機をキャンセルし、新しい待機サイクルを開始）
    func reset() {
        guard !isPaused, onTickHandler != nil else { return }

        // 現在のタスクをキャンセルして新しいサイクルを開始
        taskOwner.cancel()
        startTimerLoop()

        Logger.slideshow.debug("Slideshow timer reset")
    }

    /// 間隔を更新
    /// - Parameter interval: 新しい間隔（秒）
    func updateInterval(_ interval: Int) {
        let clampedInterval = max(1, min(60, interval))
        currentInterval = clampedInterval

        // 実行中ならリセットして新しい間隔を適用
        if isRunning {
            reset()
        }

        Logger.slideshow.info("Slideshow interval updated: \(clampedInterval, privacy: .public)s")
    }

    // MARK: - Private Methods

    private func startTimerLoop() {
        let generation = taskOwner.begin()
        let interval = Duration.seconds(currentInterval)
        let sleeper = self.sleeper
        let owner = taskOwner
        let task = Task { [weak self, weak owner] in
            while !Task.isCancelled {
                do {
                    // self を保持せずに待機する。owner の deinit が Task を cancel できる。
                    try await sleeper(interval)
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }
                let handler = self?.handlerForTick(generation: generation)
                await handler?()
            }
            owner?.finish(generation: generation)
        }
        taskOwner.install(task, generation: generation)
    }

    private func handlerForTick(generation: UUID) -> (@MainActor () async -> Void)? {
        guard taskOwner.snapshot().generation == generation, !isPaused else { return nil }
        return onTickHandler
    }

    #if DEBUG
    func _debugTaskSnapshot() -> TaskSnapshot {
        let snapshot = taskOwner.snapshot()
        return TaskSnapshot(activeTasks: snapshot.activeTasks, generation: snapshot.generation)
    }
    #endif
}
