import AppKit
import Foundation

/// 画像ブラウザーの表示可能な状態遷移。
///
/// `selection` が存在する状態では、URL・index・画像・load ID は必ず同じ commit に由来する。
/// リストの差し替えや非同期ロードの途中で、これらを個別に更新してはならない。
enum BrowserSessionPhase: Equatable, Sendable {
    case initial
    case scanning
    case loading
    case ready
    case deleting
    case empty
    case failed
}

/// 実際に画面へ表示することが確定した画像の atomic snapshot。
struct BrowserSelection {
    let url: URL
    let index: Int
    let image: NSImage
    let loadID: UUID
}

/// まだ表示へ commit していないロード要求。
struct PendingBrowserLoad: Equatable, Sendable {
    let url: URL
    let index: Int
    let loadID: UUID
    let completionPhase: BrowserSessionPhase
}

/// URL 集合の差し替え後に必要な処理。
enum BrowserURLTransition: Equatable, Sendable {
    case empty
    case preserved(index: Int)
    case load(index: Int)
}

/// phase、ソート済み URL、確定済み selection、pending load を一括所有する domain state。
struct BrowserSessionState {
    private(set) var phase: BrowserSessionPhase = .initial
    private(set) var sortedURLs: [URL] = []
    private(set) var selection: BrowserSelection?
    private(set) var pendingLoad: PendingBrowserLoad?

    /// 初回 scan は pending load 発行前にも空表示へ落とさず loading を示す。
    var isLoading: Bool {
        pendingLoad != nil || (phase == .scanning && selection == nil)
    }

    mutating func beginScan(clearSelection: Bool) {
        phase = .scanning
        sortedURLs = clearSelection ? [] : sortedURLs
        if clearSelection {
            selection = nil
        }
        pendingLoad = nil
        assertInvariants()
    }

    /// scan progress は表示済み selection を anchor として再解決する。
    /// 初回画像がまだ commit されていない場合も URL は常にソートして保持する。
    mutating func updateScanProgress(_ urls: [URL]) {
        sortedURLs = Self.sort(urls)
        reindexCommittedSelection()
        if sortedURLs.isEmpty {
            selection = nil
        }
        phase = .scanning
        assertInvariants()
    }

    /// scan complete / reload / subdirectory / filter の共通リスト transition。
    /// committed selection は URL で anchor し、列挙順や先頭要素の変化から index を隔離する。
    @discardableResult
    mutating func transitionURLs(
        _ urls: [URL],
        anchorURL: URL?,
        fallbackIndex: Int,
        transitionPhase: BrowserSessionPhase
    ) -> BrowserURLTransition {
        precondition(transitionPhase == .scanning)
        sortedURLs = Self.sort(urls)
        pendingLoad = nil

        guard !sortedURLs.isEmpty else {
            completeEmpty()
            return .empty
        }

        reindexCommittedSelection()
        let resolvedIndex: Int
        if let anchorURL,
           let anchoredIndex = sortedURLs.firstIndex(where: { Self.sameFile($0, anchorURL) }) {
            resolvedIndex = anchoredIndex
        } else {
            resolvedIndex = max(0, min(fallbackIndex, sortedURLs.count - 1))
        }

        if let selection, Self.sameFile(selection.url, sortedURLs[resolvedIndex]) {
            self.selection = BrowserSelection(
                url: selection.url,
                index: resolvedIndex,
                image: selection.image,
                loadID: selection.loadID
            )
            phase = .ready
            assertInvariants()
            return .preserved(index: resolvedIndex)
        }

        phase = transitionPhase
        assertInvariants()
        return .load(index: resolvedIndex)
    }

    /// index ではなく、その時点の URL を load identity に含める。
    @discardableResult
    mutating func beginLoad(
        at index: Int,
        completionPhase: BrowserSessionPhase = .ready
    ) -> PendingBrowserLoad? {
        guard sortedURLs.indices.contains(index) else { return nil }
        let pending = PendingBrowserLoad(
            url: sortedURLs[index],
            index: index,
            loadID: UUID(),
            completionPhase: completionPhase
        )
        pendingLoad = pending
        if completionPhase == .ready, selection != nil {
            phase = .loading
        }
        assertInvariants()
        return pending
    }

    /// URL/index/loadID がすべて現在の pending request と一致したときだけ commit する。
    @discardableResult
    mutating func commit(image: NSImage, for pending: PendingBrowserLoad) -> Bool {
        guard pendingLoad == pending,
              sortedURLs.indices.contains(pending.index),
              Self.sameFile(sortedURLs[pending.index], pending.url) else {
            return false
        }
        selection = BrowserSelection(
            url: pending.url,
            index: pending.index,
            image: image,
            loadID: pending.loadID
        )
        pendingLoad = nil
        phase = pending.completionPhase
        assertInvariants()
        return true
    }

    mutating func cancelPendingLoad() {
        guard let cancelled = pendingLoad else { return }
        pendingLoad = nil
        if cancelled.completionPhase == .scanning {
            phase = .scanning
        } else {
            phase = selection == nil ? (sortedURLs.isEmpty ? .empty : .scanning) : .ready
        }
        assertInvariants()
    }

    mutating func failPendingLoad(_ pending: PendingBrowserLoad) {
        guard pendingLoad == pending else { return }
        pendingLoad = nil
        if selection == nil {
            phase = .failed
        } else {
            phase = .ready
        }
        assertInvariants()
    }

    mutating func failSession() {
        phase = .failed
        selection = nil
        pendingLoad = nil
        assertInvariants()
    }

    mutating func completeEmpty() {
        phase = .empty
        sortedURLs = []
        selection = nil
        pendingLoad = nil
        assertInvariants()
    }

    /// 破壊操作の直前に使う production guard。
    /// debug assertion とは別に false を返し、不整合な URL への副作用を止める。
    func validatedSelectionForSideEffect() -> BrowserSelection? {
        guard phase == .ready || phase == .loading else { return nil }
        guard invariantsHold(), let selection else { return nil }
        guard sortedURLs.indices.contains(selection.index),
              Self.sameFile(sortedURLs[selection.index], selection.url) else {
            return nil
        }
        return selection
    }

    func isCurrentActionable(_ captured: BrowserSelection) -> Bool {
        guard let selection = validatedSelectionForSideEffect() else { return false }
        return selection.loadID == captured.loadID && Self.sameFile(selection.url, captured.url)
    }

    /// await を跨ぐ削除が同じ committed selection を保持しているかだけを確認する。
    /// actionable phase は要求しないため、新規副作用開始のguardには使用しない。
    func matchesCommittedIdentity(_ captured: BrowserSelection) -> Bool {
        guard invariantsHold(), let selection else { return false }
        return selection.loadID == captured.loadID && Self.sameFile(selection.url, captured.url)
    }

    mutating func beginDeletion(_ captured: BrowserSelection) -> Bool {
        guard isCurrentActionable(captured) else { return false }
        pendingLoad = nil
        phase = .deleting
        assertInvariants()
        return true
    }

    mutating func cancelDeletion(_ captured: BrowserSelection) {
        guard phase == .deleting, matchesCommittedIdentity(captured) else { return }
        phase = .ready
        assertInvariants()
    }

    /// Trash 成功後、削除済み URL を除いたリストと次の load target を同じ mutation で確定する。
    /// 選択自体は画像ロード成功時にだけ commit される。
    mutating func commitDeletionAndBeginNextLoad(
        _ captured: BrowserSelection
    ) -> PendingBrowserLoad? {
        guard phase == .deleting, matchesCommittedIdentity(captured) else { return nil }
        let remaining = sortedURLs.filter { !Self.sameFile($0, captured.url) }
        guard !remaining.isEmpty else {
            completeEmpty()
            return nil
        }

        sortedURLs = remaining
        selection = nil
        phase = .scanning
        let nextIndex = min(captured.index, remaining.count - 1)
        let pending = beginLoad(at: nextIndex)
        assertInvariants()
        return pending
    }

    func invariantsHold() -> Bool {
        let isSorted = zip(sortedURLs, sortedURLs.dropFirst()).allSatisfy { lhs, rhs in
            lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) != .orderedDescending
        }
        guard isSorted else { return false }

        if let selection {
            guard sortedURLs.indices.contains(selection.index),
                  Self.sameFile(sortedURLs[selection.index], selection.url) else {
                return false
            }
        } else if phase != .initial && phase != .scanning && phase != .empty && phase != .failed {
            return false
        }

        if let pendingLoad {
            guard sortedURLs.indices.contains(pendingLoad.index),
                  Self.sameFile(sortedURLs[pendingLoad.index], pendingLoad.url) else {
                return false
            }
        }

        if phase == .empty {
            guard sortedURLs.isEmpty, selection == nil, pendingLoad == nil else { return false }
        }
        if phase == .failed || phase == .initial {
            guard selection == nil, pendingLoad == nil else { return false }
        }
        return true
    }

    private mutating func reindexCommittedSelection() {
        guard let selection else { return }
        guard let newIndex = sortedURLs.firstIndex(where: { Self.sameFile($0, selection.url) }) else {
            self.selection = nil
            return
        }
        self.selection = BrowserSelection(
            url: selection.url,
            index: newIndex,
            image: selection.image,
            loadID: selection.loadID
        )
    }

    private func assertInvariants() {
        assert(invariantsHold(), "BrowserSessionState invariant violation")
    }

    private static func sort(_ urls: [URL]) -> [URL] {
        urls.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
    }

    /// 同一 file 判定。main thread 上で全件 filter / firstIndex に使うため、
    /// ファイルシステムに触れない字句比較に限定する（`resolvingSymlinksInPath` は
    /// path 成分ごとに `lstat` するため NAS で UI を固める）。URL は同じ scan 由来で
    /// prefix が揃っているので、symlink 解決なしで一致判定できる。
    private static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardized.path == rhs.standardized.path
    }
}
