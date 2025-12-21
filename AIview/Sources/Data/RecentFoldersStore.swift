import Foundation
import os

/// 最近開いたフォルダ履歴の永続化プロトコル
/// Requirements: 1.4, 1.5
protocol RecentFoldersStoreProtocol: Sendable {
    func getRecentFolders() -> [URL]
    func addRecentFolder(_ url: URL)
    func removeRecentFolder(_ url: URL)
    func clearRecentFolders()

    // Security-Scoped Bookmark support
    func getBookmarkData(for url: URL) -> Data?
    func restoreURL(from bookmarkData: Data) -> URL?
    func startAccessingFolder(_ url: URL) -> Bool
    func stopAccessingFolder(_ url: URL)
}

/// 最近開いたフォルダ履歴の永続化実装
/// Security-Scoped Bookmarkを使用してアクセス権限を保持
final class RecentFoldersStore: RecentFoldersStoreProtocol, @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let maxEntries = 10
    private let urlsKey = "recentFolderURLs"
    private let bookmarksKey = "recentFolderBookmarks"

    private var accessedURLs: Set<URL> = []
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// 最近開いたフォルダのURL一覧を取得
    func getRecentFolders() -> [URL] {
        lock.lock()
        defer { lock.unlock() }

        guard let paths = userDefaults.stringArray(forKey: urlsKey) else {
            return []
        }
        return paths.compactMap { URL(fileURLWithPath: $0) }
    }

    /// フォルダをリストに追加（既存の場合は先頭に移動）
    func addRecentFolder(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }

        var paths = userDefaults.stringArray(forKey: urlsKey) ?? []
        let path = url.path

        // 既存のエントリを削除
        paths.removeAll { $0 == path }

        // 先頭に追加
        paths.insert(path, at: 0)

        // 最大件数を維持
        if paths.count > maxEntries {
            paths = Array(paths.prefix(maxEntries))
        }

        userDefaults.set(paths, forKey: urlsKey)

        // Security-Scoped Bookmarkを保存
        saveBookmark(for: url)

        Logger.app.debug("Added recent folder: \(url.lastPathComponent, privacy: .public), total: \(paths.count, privacy: .public)")
    }

    /// フォルダをリストから削除
    func removeRecentFolder(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }

        var paths = userDefaults.stringArray(forKey: urlsKey) ?? []
        paths.removeAll { $0 == url.path }
        userDefaults.set(paths, forKey: urlsKey)

        // Bookmarkも削除
        removeBookmark(for: url)

        Logger.app.debug("Removed recent folder: \(url.lastPathComponent, privacy: .public)")
    }

    /// すべての履歴をクリア
    func clearRecentFolders() {
        lock.lock()
        defer { lock.unlock() }

        userDefaults.removeObject(forKey: urlsKey)
        userDefaults.removeObject(forKey: bookmarksKey)

        Logger.app.info("Cleared all recent folders")
    }

    // MARK: - Security-Scoped Bookmark Support

    /// URLのSecurity-Scoped Bookmark Dataを取得
    func getBookmarkData(for url: URL) -> Data? {
        lock.lock()
        defer { lock.unlock() }

        guard let bookmarks = userDefaults.dictionary(forKey: bookmarksKey) as? [String: Data] else {
            return nil
        }
        return bookmarks[url.path]
    }

    /// Bookmark DataからURLを復元
    func restoreURL(from bookmarkData: Data) -> URL? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                Logger.app.warning("Bookmark is stale, need to refresh")
                // 古いBookmarkの場合は新しいものを作成すべきだが、
                // ここでは古いURLを返す
            }

            return url
        } catch {
            Logger.app.error("Failed to restore URL from bookmark: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Security-Scopedリソースへのアクセスを開始
    func startAccessingFolder(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if accessedURLs.contains(url) {
            return true
        }

        let success = url.startAccessingSecurityScopedResource()
        if success {
            accessedURLs.insert(url)
            Logger.app.debug("Started accessing security-scoped resource: \(url.lastPathComponent, privacy: .public)")
        } else {
            Logger.app.warning("Failed to start accessing security-scoped resource: \(url.lastPathComponent, privacy: .public)")
        }
        return success
    }

    /// Security-Scopedリソースへのアクセスを終了
    func stopAccessingFolder(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }

        if accessedURLs.contains(url) {
            url.stopAccessingSecurityScopedResource()
            accessedURLs.remove(url)
            Logger.app.debug("Stopped accessing security-scoped resource: \(url.lastPathComponent, privacy: .public)")
        }
    }

    // MARK: - Private Methods

    private func saveBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )

            var bookmarks = userDefaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
            bookmarks[url.path] = bookmarkData
            userDefaults.set(bookmarks, forKey: bookmarksKey)

            Logger.app.debug("Saved bookmark for: \(url.lastPathComponent, privacy: .public)")
        } catch {
            Logger.app.error("Failed to create bookmark: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func removeBookmark(for url: URL) {
        var bookmarks = userDefaults.dictionary(forKey: bookmarksKey) as? [String: Data] ?? [:]
        bookmarks.removeValue(forKey: url.path)
        userDefaults.set(bookmarks, forKey: bookmarksKey)
    }
}
