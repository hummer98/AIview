import Foundation
import os

/// Slideshowの状態、timer、間隔設定を1か所で所有するcontroller。
/// Imageの選択は所有せず、tick時のactionを呼び出し側から受け取る。
@MainActor
@Observable
final class SlideshowController {
    private(set) var isActive = false
    private(set) var isPaused = false
    private(set) var interval: Int
    var isSettingsPresented = false

    private let settingsStore: SettingsStore
    private var timer: SlideshowTimer?
    private var thumbnailVisibilityBeforeStart = true

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
        interval = settingsStore.slideshowIntervalSeconds
    }

    var statusText: String {
        if isPaused { return "一時停止中" }
        if isActive { return "再生中 \(interval)秒" }
        return ""
    }

    /// - Returns: start時に表示するtoast文言。
    func start(
        interval requestedInterval: Int,
        thumbnailIsVisible: Bool,
        onTick: @escaping @MainActor () async -> Void
    ) -> String {
        let clampedInterval = max(1, min(60, requestedInterval))
        interval = clampedInterval
        thumbnailVisibilityBeforeStart = thumbnailIsVisible
        isActive = true
        isPaused = false
        settingsStore.slideshowIntervalSeconds = clampedInterval

        let timer = SlideshowTimer()
        self.timer?.stop()
        self.timer = timer
        timer.start(interval: clampedInterval, onTick: onTick)

        Logger.slideshow.info("Slideshow started: interval=\(clampedInterval, privacy: .public)s")
        return "スライドショー開始 \(clampedInterval)秒間隔"
    }

    /// - Returns: pause/resume時に表示するtoast文言。activeでない場合はnil。
    func togglePause() -> String? {
        guard isActive else { return nil }

        if isPaused {
            timer?.resume()
            isPaused = false
            Logger.slideshow.info("Slideshow resumed")
            return "スライドショー再開"
        }

        timer?.pause()
        isPaused = true
        Logger.slideshow.info("Slideshow paused")
        return "スライドショー一時停止"
    }

    /// - Returns: start前のthumbnail表示状態。activeでない場合はnil。
    func stop() -> Bool? {
        guard isActive else { return nil }

        timer?.stop()
        timer = nil
        isActive = false
        isPaused = false
        Logger.slideshow.info("Slideshow stopped")
        return thumbnailVisibilityBeforeStart
    }

    /// scene終了用。UI notificationを発生させずにTaskとstateを終了する。
    func shutdown() {
        timer?.stop()
        timer = nil
        isActive = false
        isPaused = false
        isSettingsPresented = false
    }

    /// - Returns: 変更後の間隔。変更しなかった場合はnil。
    func adjustInterval(_ delta: Int) -> Int? {
        guard isActive else { return nil }
        let newInterval = max(1, min(60, interval + delta))
        guard newInterval != interval else { return nil }

        interval = newInterval
        timer?.updateInterval(newInterval)
        settingsStore.slideshowIntervalSeconds = newInterval
        Logger.slideshow.info("Slideshow interval adjusted: \(newInterval, privacy: .public)s")
        return newInterval
    }

    func resetTimer() {
        timer?.reset()
    }
}
