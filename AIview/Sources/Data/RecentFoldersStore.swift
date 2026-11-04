import Foundation
import os

/// 最近開いたフォルダ履歴の永続化実装。
///
/// Developer ID の非 sandbox 配布を前提とし、plain な正規化 path だけを保存する。
/// 存在しない path も外付け volume / network mount が戻る可能性があるため履歴に保持し、
/// open 時に通常の「path not found」error として扱う。
final class RecentFoldersStore {
    static let urlsKey = "recentFolderURLs"
    static let legacyBookmarksKey = "recentFolderBookmarks"
    static let migrationVersionKey = "recentFoldersPathMigrationVersion"
    static let pathsBackupKey = "recentFolderURLs.prePathMigrationBackup.v1"
    static let bookmarksBackupKey = "recentFolderBookmarks.prePathMigrationBackup.v1"

    private let currentMigrationVersion = 1
    private let userDefaults: UserDefaults
    private let maxEntries = 10
    private let lock = NSLock()

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        migrateLegacyStorageIfNeeded()
    }

    func getRecentFolders() -> [URL] {
        lock.withLock {
            storedNormalizedPaths().map { URL(fileURLWithPath: $0) }
        }
    }

    /// フォルダをリストに追加（既存の場合は先頭に移動）。
    func addRecentFolder(_ url: URL) {
        lock.withLock {
            var paths = storedNormalizedPaths()
            let path = normalizedPath(url)
            paths.removeAll { $0 == path }
            paths.insert(path, at: 0)
            persist(Array(paths.prefix(maxEntries)))
            Logger.app.debug("Added recent folder; total: \(paths.count, privacy: .public)")
        }
    }

    func removeRecentFolder(_ url: URL) {
        lock.withLock {
            var paths = storedNormalizedPaths()
            let path = normalizedPath(url)
            paths.removeAll { $0 == path }
            persist(paths)
            Logger.app.debug("Removed recent folder")
        }
    }

    func clearRecentFolders() {
        lock.withLock {
            userDefaults.removeObject(forKey: Self.urlsKey)
            userDefaults.removeObject(forKey: Self.legacyBookmarksKey)
            userDefaults.removeObject(forKey: Self.pathsBackupKey)
            userDefaults.removeObject(forKey: Self.bookmarksBackupKey)
            Logger.app.info("Cleared all recent folders")
        }
    }

    /// bookmark/path 混在形式から plain standardized path へ一度だけ移行する。
    ///
    /// 旧 bookmark dictionary は path を key に保存していたため、Data を解決せず key を
    /// migration input として利用できる。移行前 value は rollback 用に1 release分残す。
    private func migrateLegacyStorageIfNeeded() {
        lock.withLock {
            guard userDefaults.integer(forKey: Self.migrationVersionKey) < currentMigrationVersion else {
                return
            }

            let legacyPaths = userDefaults.stringArray(forKey: Self.urlsKey) ?? []
            let legacyBookmarks = userDefaults.dictionary(forKey: Self.legacyBookmarksKey) ?? [:]

            if userDefaults.object(forKey: Self.pathsBackupKey) == nil,
               userDefaults.object(forKey: Self.urlsKey) != nil {
                userDefaults.set(legacyPaths, forKey: Self.pathsBackupKey)
            }
            if userDefaults.object(forKey: Self.bookmarksBackupKey) == nil,
               userDefaults.object(forKey: Self.legacyBookmarksKey) != nil {
                userDefaults.set(legacyBookmarks, forKey: Self.bookmarksBackupKey)
            }

            // 履歴順を持つ旧 path 配列を優先し、path 配列にない bookmark key は
            // dictionary 順に依存しないよう標準化後の昇順で末尾へ補完する。
            let bookmarkPaths = legacyBookmarks.keys.map {
                normalizedPath(URL(fileURLWithPath: $0))
            }.sorted()
            let normalized = normalizedUniquePaths(legacyPaths + bookmarkPaths)
            let migrated = Array(normalized.prefix(maxEntries))
            persist(migrated)

            // UserDefaults の read-back で保存を確認してから旧 bookmark を撤去する。
            guard userDefaults.stringArray(forKey: Self.urlsKey) == migrated else {
                Logger.app.error("Recent folder path migration could not be verified")
                return
            }
            userDefaults.removeObject(forKey: Self.legacyBookmarksKey)
            userDefaults.set(currentMigrationVersion, forKey: Self.migrationVersionKey)
            Logger.app.info("Migrated recent folders to normalized paths; total: \(migrated.count, privacy: .public)")
        }
    }

    private func storedNormalizedPaths() -> [String] {
        let paths = userDefaults.stringArray(forKey: Self.urlsKey) ?? []
        let normalized = Array(normalizedUniquePaths(paths).prefix(maxEntries))
        if normalized != paths {
            persist(normalized)
        }
        return normalized
    }

    private func normalizedUniquePaths(_ paths: [String]) -> [String] {
        var seen = Set<String>()
        return paths.compactMap { path in
            guard !path.isEmpty else { return nil }
            let normalized = normalizedPath(URL(fileURLWithPath: path))
            guard seen.insert(normalized).inserted else { return nil }
            return normalized
        }
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    private func persist(_ paths: [String]) {
        userDefaults.set(paths, forKey: Self.urlsKey)
    }
}
