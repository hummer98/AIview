import AppKit
import Foundation
import os

/// サムネイル生成ジョブの優先度。
/// 表示中 ± `ThumbnailCarousel.priorityWindowRadius` の範囲は `.high`、それ以外は `.low`。
/// background warmer（フォルダ全件の disk キャッシュ充填）は `.background` を使う。
enum ThumbnailPriority {
    case high
    case low
    case background

    var qos: QualityOfService {
        switch self {
        case .high: return .utility
        case .low: return .utility
        case .background: return .background
        }
    }

    var queuePriority: Operation.QueuePriority {
        switch self {
        case .high: return .high
        case .low: return .normal
        case .background: return .veryLow
        }
    }
}

/// Task コンテキストと DispatchQueue コンテキストの両方から
/// 安全に参照できるキャンセルフラグ。
/// withTaskCancellationHandler の onCancel で `cancel()` を呼び、
/// DispatchQueue 内部では `isCancelled` を各工程で参照して早期 return する。
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _cancelled = false

    func cancel() {
        lock.withLock { _cancelled = true }
    }

    var isCancelled: Bool {
        lock.withLock { _cancelled }
    }
}

/// continuation.resume を最初の呼び出しだけ通すための one-shot フラグ。
/// BlockOperation 本体 (happy path / early cancel) と completionBlock (本体が一度も
/// 走らなかった稀少ケースの救済) の両方から resume されうるため、二重 resume を防ぐ。
final class ResumeGuard: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// 最初の呼び出し時のみ true を返し、以降は false を返す。
    func consume() -> Bool {
        lock.withLock { done in
            if done { return false }
            done = true
            return true
        }
    }
}

/// URL → Operation の対応表を保持し、enqueue 済みで未完了のサムネイル生成ジョブの
/// `queuePriority` を動的に書き換える。currentIndex 変化時にウィンドウ内 URL を
/// `.high`、範囲外を `.normal` に遷移させる。
/// map 操作は lock 下、queuePriority 書換えは lock 外で行う分割ロック設計。
final class OperationRegistry: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[URL: Operation]>(initialState: [:])

    func register(_ op: Operation, for url: URL) {
        lock.withLock { map in
            map[url] = op
        }
    }

    func remove(for url: URL) {
        lock.withLock { map in
            _ = map.removeValue(forKey: url)
        }
    }

    /// `highPriorityURLs` に含まれる URL を `.high`、それ以外を `.normal` に設定する。
    /// 手順: (1) lock 下で map スナップショット取得 → lock 解放 →
    /// (2) 反復中に `isFinished`/`isCancelled` をスキップ条件とし queuePriority を書換える。
    /// priority 書換え時の KVO 通知と map 操作の deadlock を回避する意図。
    func updatePriorities(highPriorityURLs: Set<URL>) {
        let snapshot: [(URL, Operation)] = lock.withLock { map in
            Array(map)
        }
        for (url, op) in snapshot {
            if op.isFinished || op.isCancelled { continue }
            let newPriority: Operation.QueuePriority = highPriorityURLs.contains(url) ? .high : .normal
            if op.queuePriority != newPriority {
                op.queuePriority = newPriority
            }
        }
    }

    /// テスト支援用。現在登録中の Operation 数を返す。
    var count: Int {
        lock.withLock { map in map.count }
    }
}

/// サムネイル生成のドメイン層エントリポイント。
/// `OperationQueue` ベースの bounded concurrency と URL 単位の `OperationRegistry` を所有し、
/// Presentation (ThumbnailCarousel) と background warmer (ThumbnailCacheManager 経由) の
/// 両方から共通利用される。
///
/// 設計の要点:
/// - Sendable な final class（内部状態は OperationQueue/Registry/Instrumentation で各々 thread-safe）
/// - `shared` シングルトンで queue/registry/instrumentation をプロセス全体で共有
/// - 並列度: `[4, 8]` クランプ（2 コア機での I/O パイプ確保 + 高コア機での MainActor 戻り飽和回避）
final class ThumbnailGenerator: @unchecked Sendable {
    /// アプリ全体で共有する単一インスタンス。
    static let shared = ThumbnailGenerator()

    /// 同時生成上限。`activeProcessorCount` は OS が現時点で有効としているコア数
    /// (thermal throttle / Low Power Mode を反映) なので `processorCount` より妥当。
    /// `static let` は初回アクセス時の lazy 評価で以降固定となり、起動中のコア可用数
    /// 変化には追従しない前提。`[4, 8]` にクランプするのは 2 コア機でも I/O パイプを
    /// 埋める最低並列数を確保し、かつ MainActor 戻り/SSD 帯域の飽和を避けるため。
    static let concurrencyLimit: Int = {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(max(cores, 4), 8)
    }()

    /// サムネイル生成用の専用 OperationQueue。
    /// `maxConcurrentOperationCount` で上限を制御し、`BlockOperation` 単位で
    /// `queuePriority` / `qualityOfService` を個別に設定する。
    let operationQueue: OperationQueue

    /// プロセス全体で共有する Operation レジストリ。
    /// URL は絶対パスベースでアプリ全体一意と仮定（複数ウィンドウで同じフォルダを
    /// 開く運用は未サポート、Phase 2 で `(windowID, URL)` キー化へ拡張予定）。
    let operationRegistry: OperationRegistry

    /// queue の並列度を計測するインストルメンテーション（アプリ全体で共有）
    var instrumentation: QueueInstrumentation { QueueInstrumentation.thumbnailQueueShared }

    init(
        concurrencyLimit: Int = ThumbnailGenerator.concurrencyLimit,
        operationRegistry: OperationRegistry = OperationRegistry()
    ) {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = concurrencyLimit
        queue.qualityOfService = .utility
        queue.name = "com.ridgeroot.AIview.thumbnailGeneration"
        self.operationQueue = queue
        self.operationRegistry = operationRegistry
    }

    /// 専用 OperationQueue でサムネイル生成を実行する。
    /// - キャンセル経路:
    ///   C1 caller が Task をキャンセル → `Task.isCancelled`
    ///   → C2 `withTaskCancellationHandler.onCancel` が `CancelFlag.cancel()` を発火
    ///   → C3 同時に `operation.cancel()` を呼び、キュー内未実行なら main 実行を skip
    ///   body は毎 I/O 呼出し前に `op?.isCancelled || cancelFlag.isCancelled` をチェック。
    /// - continuation resume 契約: 本体が成功時に resume。本体が一度も走らない稀少ケース
    ///   （addOperation 直後に isCancelled）は completionBlock が救済 resume。`ResumeGuard`
    ///   が one-shot 化する。
    func generate(
        for url: URL,
        size: CGFloat,
        priority: ThumbnailPriority = .low
    ) async -> NSImage? {
        let flag = CancelFlag()
        let registry = self.operationRegistry
        let queue = self.operationQueue
        let inst = self.instrumentation
        let guardFlag = ResumeGuard()
        let op = BlockOperation()
        op.queuePriority = priority.queuePriority
        op.qualityOfService = priority.qos

        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<NSImage?, Never>) in
                op.addExecutionBlock { [weak op] in
                    // 実行中ジョブだけを peakInFlight に数える（pre-dequeue cancel は除外）。
                    inst.enter()
                    defer { inst.leave() }

                    if op?.isCancelled == true || flag.isCancelled {
                        if guardFlag.consume() {
                            continuation.resume(returning: nil)
                        }
                        return
                    }

                    let result = Self.renderThumbnail(at: url, size: size) {
                        op?.isCancelled == true || flag.isCancelled
                    }

                    if guardFlag.consume() {
                        continuation.resume(returning: result)
                    }
                }
                op.completionBlock = {
                    registry.remove(for: url)
                    // fallback: body が一度も走らなかった稀少ケース (addOperation 直後 cancel 等)
                    if guardFlag.consume() {
                        continuation.resume(returning: nil)
                    }
                }

                registry.register(op, for: url)
                queue.addOperation(op)
            }
        } onCancel: {
            flag.cancel()
            op.cancel()
        }
    }

    /// 実 I/O と CGImage → NSImage の変換。cancellation は `isCancelled` クロージャで問い合わせる。
    /// CGImageSource 呼出しの前後 3 箇所でチェックし、cancelled なら nil を返す。
    /// BlockOperation の background thread から呼ばれるため `nonisolated` でなければならない。
    nonisolated private static func renderThumbnail(
        at url: URL,
        size: CGFloat,
        isCancelled: () -> Bool
    ) -> NSImage? {
        if isCancelled() { return nil }

        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }

        if isCancelled() { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, // EXIF orientation を適用
            kCGImageSourceThumbnailMaxPixelSize: size * 2, // Retina対応
            kCGImageSourceShouldCacheImmediately: true
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary) else {
            return nil
        }

        if isCancelled() { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}
