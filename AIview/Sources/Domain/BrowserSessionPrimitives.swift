import Foundation

/// 兄弟フォルダ移動の方向。
enum SiblingFolderDirection {
    case previous
    case next
}

/// 「前回の表示位置を復元しますか？」確認プロンプトの状態。
/// indexは持たず、確定時にimage URL一覧からファイル名で再解決する。
struct LastViewedRestore: Equatable {
    let filename: String
}

/// 1回のfolder openに属する非同期結果を識別するsession token。
struct BrowserSessionID: Equatable, Hashable, Sendable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// race testでstate commit直前を制御するためのsuspension point。
enum BrowserSessionCheckpoint: Sendable {
    case favoritesLoaded
    case scanEvent(FolderScanEvent)
    case scanError
}

/// 1つの世代付きTask handleを所有するslot。
/// 古いTaskの完了が新世代のhandleを消さないことをidentityで保証する。
struct GenerationTaskSlot {
    struct Snapshot: Equatable, Sendable {
        let activeTasks: Int
        let generation: UUID?

        var isIdle: Bool { activeTasks == 0 && generation == nil }
    }

    private var task: Task<Void, Never>?
    private(set) var generation: UUID?

    mutating func begin() -> UUID {
        cancel()
        let generation = UUID()
        self.generation = generation
        return generation
    }

    mutating func install(_ task: Task<Void, Never>, generation: UUID) {
        guard self.generation == generation else {
            task.cancel()
            return
        }
        self.task = task
    }

    @discardableResult
    mutating func finish(generation: UUID) -> Bool {
        guard self.generation == generation else { return false }
        task = nil
        self.generation = nil
        return true
    }

    mutating func cancel() {
        task?.cancel()
        task = nil
        generation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(activeTasks: generation == nil ? 0 : 1, generation: generation)
    }
}
