import SwiftUI
import os

private final class ThumbnailActivityTaskOwner: Sendable {
    private struct State {
        var task: Task<Void, Never>?
        var generation: UUID?
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    func begin() -> UUID? {
        lock.withLock { state in
            guard state.generation == nil else { return nil }
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

    var activeTaskCount: Int {
        lock.withLock { $0.generation == nil ? 0 : 1 }
    }

    deinit {
        cancel()
    }
}

/// ツールバー右端に表示する「サムネイル生成キュー稼働インジケータ」用のスナップショット値型。
/// View ボディから切り出した純構造体なので、SwiftUI に依存せず単体テスト可能。
/// - 表示判定 (`shouldDisplay`) と詳細ツールチップ整形 (`tooltipText`) のロジックを集約する。
struct ThumbnailActivityState: Sendable, Equatable {
    /// 現在 in-flight のサムネイル生成数
    let inFlight: Int
    /// ピーク（uptime ベース）
    let peak: Int
    /// 累計エンキュー数
    let totalEnqueued: UInt64
    /// サムネイルメモリキャッシュのヒット率（0.0-1.0）
    let memoryHitRate: Double
    /// サムネイルディスクキャッシュのヒット率（0.0-1.0）
    let diskHitRate: Double
    /// 直近に inFlight > 0 を観測した時刻。フリッカー抑制と fade-out 判定に使う
    let lastNonZeroAt: Date?

    /// アイドル復帰後にインジケータを残しておく時間（秒）。
    /// 1 秒以内に再度 in-flight が立てばちらつきを抑制でき、それ以降は fade-out させる。
    static let fadeOutWindow: TimeInterval = 1.0

    static let idle = ThumbnailActivityState(
        inFlight: 0,
        peak: 0,
        totalEnqueued: 0,
        memoryHitRate: 0,
        diskHitRate: 0,
        lastNonZeroAt: nil
    )

    func shouldDisplay(now: Date, fadeOutAfter: TimeInterval = ThumbnailActivityState.fadeOutWindow) -> Bool {
        if inFlight > 0 { return true }
        guard let last = lastNonZeroAt else { return false }
        return now.timeIntervalSince(last) < fadeOutAfter
    }

    /// hover 時の詳細ツールチップ。0-1 表記のヒット率は % へ整形して表示する。
    var tooltipText: String {
        let memPct = Int((memoryHitRate * 100).rounded())
        let diskPct = Int((diskHitRate * 100).rounded())
        return "走行 \(inFlight) / ピーク \(peak) / total \(totalEnqueued), mem hit \(memPct)% / disk hit \(diskPct)%"
    }
}

/// `ThumbnailActivityIndicator` の polling/state を保持する @Observable モデル。
/// 親 View は `isVisible` を見て、不可視時はインジケータを HStack から取り除ける
/// （`.frame(width: 0)` 方式だと HStack の `spacing` が両側に残り、レイアウトが詰まらないため）。
@MainActor
@Observable
final class ThumbnailActivityModel {
    typealias Sleeper = @Sendable (Duration) async throws -> Void

    struct TaskSnapshot: Equatable, Sendable {
        let activeTasks: Int

        var isIdle: Bool { activeTasks == 0 }
    }

    private(set) var state: ThumbnailActivityState = .idle
    private(set) var now: Date = .distantPast

    var isVisible: Bool { state.shouldDisplay(now: now) }

    private let metricsCollector: MetricsCollector
    private let taskOwner = ThumbnailActivityTaskOwner()
    private let sleeper: Sleeper

    init(metricsCollector: MetricsCollector, sleeper: Sleeper? = nil) {
        self.metricsCollector = metricsCollector
        self.sleeper = sleeper ?? { @Sendable duration in
            try await Task.sleep(for: duration)
        }
    }

    deinit {
        taskOwner.cancel()
    }

    func start() {
        guard let generation = taskOwner.begin() else { return }
        let owner = taskOwner
        let sleeper = self.sleeper
        let task = Task { @MainActor [weak self, weak owner] in
            defer { owner?.finish(generation: generation) }
            guard let metricsCollector = self?.metricsCollector else { return }
            while !Task.isCancelled {
                let snap = await metricsCollector.snapshot()
                guard !Task.isCancelled else { return }
                self?.apply(snapshot: snap, now: Date())

                // optional-chain の一時的な self 保持が終了してから sleep する。
                do {
                    try await sleeper(.seconds(1))
                } catch {
                    return
                }
            }
        }
        taskOwner.install(task, generation: generation)
    }

    func stop() {
        taskOwner.cancel()
    }

    private func apply(snapshot: MetricsSnapshot, now: Date) {
        self.now = now
        let lastNonZero: Date? = snapshot.thumbnailQueue.currentInFlight > 0
            ? now
            : state.lastNonZeroAt
        state = ThumbnailActivityState(
            inFlight: snapshot.thumbnailQueue.currentInFlight,
            peak: snapshot.thumbnailQueue.peakInFlight,
            totalEnqueued: snapshot.thumbnailQueue.totalEnqueued,
            memoryHitRate: snapshot.thumbnailMemory.hitRate,
            diskHitRate: snapshot.thumbnailDisk.hitRate,
            lastNonZeroAt: lastNonZero
        )
    }

    #if DEBUG
    func _debugTaskSnapshot() -> TaskSnapshot {
        TaskSnapshot(activeTasks: taskOwner.activeTaskCount)
    }
    #endif
}

/// サムネイル生成キューの稼働を示すツールバー用インジケータ。
/// 表示判定は親側で `model.isVisible` により行うため、本 View は常に可視のシンプルなレンダリングのみ担当する。
@MainActor
struct ThumbnailActivityIndicator: View {
    let state: ThumbnailActivityState

    @State private var rotate: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "gearshape.2.fill")
                .rotationEffect(.degrees(rotate ? 360 : 0))
                .animation(
                    .linear(duration: 2).repeatForever(autoreverses: false),
                    value: rotate
                )
            Text("\(state.inFlight)")
                .font(.system(size: 12, weight: .medium).monospacedDigit())
        }
        .foregroundColor(.secondary)
        .help(state.tooltipText)
        .accessibilityLabel("サムネイル生成中: \(state.inFlight)件")
        .onAppear {
            rotate = true
        }
    }
}
