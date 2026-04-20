import Foundation
import os

/// 専用 DispatchQueue の同時実行数を計測する軽量カウンタ。
/// `enter()` / `leave()` を `thumbnailQueue.async { ... }` の前後で呼ぶ運用を想定。
/// 内部状態は `OSAllocatedUnfairLock` で保護されており、競合なしで 20-30ns オーダーのコスト。
final class QueueInstrumentation: @unchecked Sendable {
    private struct State {
        var inFlight: Int = 0
        var peak: Int = 0
        var totalEnqueued: UInt64 = 0
        /// 1Hz サンプリングで蓄積される in-flight の値の合計
        var inFlightSamplesSum: Double = 0
        var inFlightSampleCount: UInt64 = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    init() {}

    /// async ブロックに入る直前に呼ぶ
    func enter() {
        lock.withLock { state in
            state.inFlight &+= 1
            state.totalEnqueued &+= 1
            if state.inFlight > state.peak {
                state.peak = state.inFlight
            }
        }
    }

    /// async ブロック完了時に呼ぶ
    func leave() {
        lock.withLock { state in
            if state.inFlight > 0 {
                state.inFlight -= 1
            }
        }
    }

    /// 1Hz で呼び出して平均 in-flight の母集団を増やす
    func sample() {
        lock.withLock { state in
            state.inFlightSamplesSum += Double(state.inFlight)
            state.inFlightSampleCount &+= 1
        }
    }

    func snapshot() -> QueueMetricsSnapshot {
        lock.withLock { state in
            let avg = state.inFlightSampleCount > 0
                ? state.inFlightSamplesSum / Double(state.inFlightSampleCount)
                : Double(state.inFlight)
            return QueueMetricsSnapshot(
                currentInFlight: state.inFlight,
                peakInFlight: state.peak,
                totalEnqueued: state.totalEnqueued,
                avgInFlight: avg
            )
        }
    }
}

extension QueueInstrumentation {
    /// アプリ全体で共有するサムネイル生成キュー用インストルメンテーション。
    /// クラス自身は MainActor に縛られないので Sendable closure からアクセス可能。
    static let thumbnailQueueShared = QueueInstrumentation()
}

#if DEBUG
extension QueueInstrumentation {
    /// テスト間での状態分離用フック。本番経路からは呼ばない。
    func _debugReset() {
        lock.withLock { state in
            state = State()
        }
    }
}
#endif
