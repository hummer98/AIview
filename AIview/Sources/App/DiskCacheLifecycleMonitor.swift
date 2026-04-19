import Foundation
import SwiftUI
import AppKit

/// DiskCacheStore.flush() をライフサイクルイベントで発火させるヘルパ (M3)
///
/// - `handleScenePhase(_:)` は ScenePhase の `.background` / `.inactive` 遷移で flush
/// - `NSApplication.willTerminateNotification` でも flush (dedup 用 debounce 付き)
/// - テスト可能にするため flush 実行クロージャを外から注入する
@MainActor
final class DiskCacheLifecycleMonitor {

    /// flush を呼ぶクロージャ。await 対応。
    private let flushHandler: () async -> Void

    /// 直近 flush 開始時刻（重複発火を抑止）
    private var lastFlushAt: Date?

    /// 最低 flush 間隔 (dedup)
    private let minFlushInterval: TimeInterval

    /// NSApplication.willTerminate 購読
    private var willTerminateObserver: NSObjectProtocol?

    init(
        minFlushInterval: TimeInterval = 1.0,
        flush: @escaping () async -> Void
    ) {
        self.flushHandler = flush
        self.minFlushInterval = minFlushInterval
        self.willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await self.triggerFlush(reason: "willTerminate")
            }
        }
    }

    deinit {
        if let obs = willTerminateObserver {
            NotificationCenter.default.removeObserver(obs)
        }
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background, .inactive:
            Task { @MainActor in
                await triggerFlush(reason: "scenePhase=\(phase)")
            }
        case .active:
            break
        @unknown default:
            break
        }
    }

    /// テスト用: 直接 trigger する
    func triggerFlush(reason: String) async {
        let now = Date()
        if let last = lastFlushAt, now.timeIntervalSince(last) < minFlushInterval {
            return
        }
        lastFlushAt = now
        await flushHandler()
    }

    /// テストフック
    func testHookLastFlushAt() -> Date? { lastFlushAt }
}
