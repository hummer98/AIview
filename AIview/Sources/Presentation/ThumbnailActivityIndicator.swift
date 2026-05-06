import SwiftUI

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

/// サムネイル生成キューの稼働を示すツールバー用インジケータ。
/// 1Hz で `MetricsCollector.snapshot()` を取得し、`currentInFlight > 0` のときのみ
/// 歯車アイコン + 数値を表示する。アイドル復帰後は 1 秒のフェードアウト窓を経て消える。
@MainActor
struct ThumbnailActivityIndicator: View {
    let metricsCollector: MetricsCollector

    @State private var state: ThumbnailActivityState = .idle
    @State private var now: Date = Date()
    @State private var rotate: Bool = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        let visible = state.shouldDisplay(now: now)
        return Group {
            HStack(spacing: 4) {
                Image(systemName: "gearshape.2.fill")
                    .rotationEffect(.degrees(rotate ? 360 : 0))
                    .animation(
                        visible
                            ? .linear(duration: 2).repeatForever(autoreverses: false)
                            : .default,
                        value: rotate
                    )
                Text("\(state.inFlight)")
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
            }
            .foregroundColor(.secondary)
            .help(state.tooltipText)
            .accessibilityLabel("サムネイル生成中: \(state.inFlight)件")
        }
        .frame(width: visible ? nil : 0)
        .clipped()
        .opacity(visible ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: visible)
        .onAppear {
            rotate = true
        }
        .onReceive(timer) { tick in
            now = tick
            Task { @MainActor in
                let snap = await metricsCollector.snapshot()
                let lastNonZero: Date? = snap.thumbnailQueue.currentInFlight > 0
                    ? Date()
                    : state.lastNonZeroAt
                state = ThumbnailActivityState(
                    inFlight: snap.thumbnailQueue.currentInFlight,
                    peak: snap.thumbnailQueue.peakInFlight,
                    totalEnqueued: snap.thumbnailQueue.totalEnqueued,
                    memoryHitRate: snap.thumbnailMemory.hitRate,
                    diskHitRate: snap.thumbnailDisk.hitRate,
                    lastNonZeroAt: lastNonZero
                )
            }
        }
    }
}
