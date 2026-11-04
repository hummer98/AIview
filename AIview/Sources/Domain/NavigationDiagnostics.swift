import Foundation
import os

/// 機微値を保持しない、ナビゲーション診断イベント。
///
/// URL、path、filename、prompt、metadata、error description、任意文字列は associated value に
/// できない。診断履歴を export してもユーザーデータが混入しないことを型で保証する。
enum NavigationEvent: Equatable, Sendable {
    case jumpSkippedEmpty(requestedIndex: Int)
    case jumpSkippedSameTarget(requestedIndex: Int, targetIndex: Int, displayedIndex: Int)
    case jumpRequested(fromIndex: Int, toIndex: Int, displayedIndex: Int, recordsLastViewed: Bool)
    case staleLoadRejected(index: Int)
    case loadAborted(index: Int, stage: NavigationLoadStage)
    case loadCommitted(index: Int, source: NavigationLoadSource)
    case loadCancelled(index: Int)
    case loadFailed(index: Int, category: AppError.Category)
    case liveTaskReportedCancelled(index: Int)
    case navigationDidNotCommit(targetIndex: Int, displayedIndex: Int, isLoading: Bool)

    var kind: NavigationEventKind {
        switch self {
        case .jumpSkippedEmpty: .jumpSkippedEmpty
        case .jumpSkippedSameTarget: .jumpSkippedSameTarget
        case .jumpRequested: .jumpRequested
        case .staleLoadRejected: .staleLoadRejected
        case .loadAborted: .loadAborted
        case .loadCommitted: .loadCommitted
        case .loadCancelled: .loadCancelled
        case .loadFailed: .loadFailed
        case .liveTaskReportedCancelled: .liveTaskReportedCancelled
        case .navigationDidNotCommit: .navigationDidNotCommit
        }
    }

    var isAnomaly: Bool {
        switch self {
        case .liveTaskReportedCancelled, .navigationDidNotCommit:
            true
        default:
            false
        }
    }
}

enum NavigationEventKind: String, Equatable, Sendable {
    case jumpSkippedEmpty
    case jumpSkippedSameTarget
    case jumpRequested
    case staleLoadRejected
    case loadAborted
    case loadCommitted
    case loadCancelled
    case loadFailed
    case liveTaskReportedCancelled
    case navigationDidNotCommit
}

enum NavigationLoadStage: String, Equatable, Sendable {
    case cacheHit
    case postLoad
    case mainActor
    case commit
}

enum NavigationLoadSource: String, Equatable, Sendable {
    case memoryCache
    case decoded
    case sharedDecode
}

/// Window 間で共有される bounded in-memory ring。平文ファイル出力は行わない。
final class NavigationDiagnostics: Sendable {
    static let shared = NavigationDiagnostics()

    private struct State {
        var events: [NavigationEvent] = []
    }

    private let capacity: Int
    private let state = OSAllocatedUnfairLock(initialState: State())

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    func record(_ event: NavigationEvent) {
        state.withLock { state in
            state.events.append(event)
            if state.events.count > capacity {
                state.events.removeFirst(state.events.count - capacity)
            }
        }

        let kind = event.kind.rawValue
        if event.isAnomaly {
            Logger.navigation.fault("Navigation anomaly: \(kind, privacy: .public)")
        } else {
            Logger.navigation.debug("Navigation event: \(kind, privacy: .public)")
        }
    }

    func snapshot() -> [NavigationEvent] {
        state.withLock { $0.events }
    }
}
