import Foundation
import os

/// スライドショーの自動進行タイマー管理
/// Requirements: 2.1, 4.1, 4.2, 6.3
@MainActor
final class SlideshowTimer {
    // MARK: - Properties

    private var timerTask: Task<Void, Never>?
    private var isPaused: Bool = false
    private var currentInterval: Int = 3
    private var onTickHandler: (() -> Void)?

    /// タイマーが実行中かどうか
    var isRunning: Bool {
        timerTask != nil && !isPaused
    }

    // MARK: - Public Methods

    /// タイマーを開始
    /// - Parameters:
    ///   - interval: 間隔（秒）1-60の範囲
    ///   - onTick: 間隔ごとに呼ばれるコールバック
    func start(interval: Int, onTick: @escaping () -> Void) {
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
        timerTask?.cancel()
        timerTask = nil

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
        timerTask?.cancel()
        timerTask = nil
        isPaused = false
        onTickHandler = nil

        Logger.slideshow.info("Slideshow timer stopped")
    }

    /// タイマーをリセット（現在の待機をキャンセルし、新しい待機サイクルを開始）
    func reset() {
        guard !isPaused, onTickHandler != nil else { return }

        // 現在のタスクをキャンセルして新しいサイクルを開始
        timerTask?.cancel()
        timerTask = nil
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
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }

                // 指定間隔待機
                do {
                    try await Task.sleep(nanoseconds: UInt64(self.currentInterval) * 1_000_000_000)
                } catch {
                    // キャンセルされた場合は終了
                    break
                }

                // キャンセルされていなければコールバックを実行
                if !Task.isCancelled, let handler = self.onTickHandler {
                    handler()
                }
            }
        }
    }
}
