import Foundation
import os

/// お気に入り情報の永続化管理
/// フォルダごとのお気に入り情報（ファイル名→レベル1〜5）を管理
/// Requirements: 2.1, 2.2, 2.3, 2.4
actor FavoritesStore {
    /// お気に入りデータのファイル名
    private let favoritesFileName = "favorites.json"

    /// キャッシュディレクトリ名
    private let cacheDirectoryName = ".aiview"

    /// 現在のフォルダURL
    private var currentFolderURL: URL?

    /// メモリ上のお気に入りデータ（ファイル名→レベル）
    private var favorites: [String: Int] = [:]

    /// 統合されたお気に入りデータ（フォルダURL→ファイル名→レベル）
    private var aggregatedFavorites: [URL: [String: Int]] = [:]

    /// 現在統合モードかどうか
    private var isAggregatedMode: Bool = false

    private let fileManager = FileManager.default

    // MARK: - Public Methods

    /// 指定フォルダのお気に入りを読み込み（統合モードを解除）
    /// - Parameter folderURL: 対象フォルダのURL
    func loadFavorites(for folderURL: URL) {
        currentFolderURL = folderURL
        favorites = [:]

        // 統合モードを解除
        isAggregatedMode = false
        aggregatedFavorites = [:]

        let favoritesURL = favoritesFileURL(for: folderURL)

        guard fileManager.fileExists(atPath: favoritesURL.path) else {
            Logger.favorites.debug("No favorites file found, starting fresh")
            return
        }

        do {
            let data = try Data(contentsOf: favoritesURL)
            favorites = try JSONDecoder().decode([String: Int].self, from: data)
            Logger.favorites.info("Loaded \(self.favorites.count, privacy: .public) favorites")
        } catch {
            Logger.favorites.warning("Failed to load favorites: \(error.localizedDescription, privacy: .public)")
            favorites = [:]
        }
    }

    /// お気に入りレベルを設定（1-5）
    /// - Parameters:
    ///   - url: 画像のURL
    ///   - level: お気に入りレベル（1〜5）
    func setFavorite(for url: URL, level: Int) throws {
        guard level >= 1, level <= 5 else {
            Logger.favorites.error("Invalid favorite level: \(level, privacy: .public)")
            return
        }

        let filename = url.lastPathComponent

        if isAggregatedMode {
            // 統合モード: 画像が属するフォルダに保存
            let rawFolderURL = url.deletingLastPathComponent()
            let rawPath = rawFolderURL.path
            // パス文字列でマッチング
            var matchedKey: URL?
            for key in aggregatedFavorites.keys {
                if key.path == rawPath {
                    matchedKey = key
                    break
                }
            }
            let folderURL = matchedKey ?? rawFolderURL
            if aggregatedFavorites[folderURL] == nil {
                aggregatedFavorites[folderURL] = [:]
            }
            aggregatedFavorites[folderURL]?[filename] = level
            try saveToDisk(folderURL: folderURL, favorites: aggregatedFavorites[folderURL] ?? [:])
        } else {
            favorites[filename] = level
            try saveToDisk()
        }

        Logger.favorites.debug("Set favorite: \(filename, privacy: .public) = \(level, privacy: .public)")
    }

    /// お気に入りを解除
    /// - Parameter url: 画像のURL
    func removeFavorite(for url: URL) throws {
        let filename = url.lastPathComponent

        if isAggregatedMode {
            // 統合モード: 画像が属するフォルダから削除
            let rawFolderURL = url.deletingLastPathComponent()
            let rawPath = rawFolderURL.path
            // パス文字列でマッチング
            var matchedKey: URL?
            for key in aggregatedFavorites.keys {
                if key.path == rawPath {
                    matchedKey = key
                    break
                }
            }
            let folderURL = matchedKey ?? rawFolderURL
            aggregatedFavorites[folderURL]?.removeValue(forKey: filename)
            try saveToDisk(folderURL: folderURL, favorites: aggregatedFavorites[folderURL] ?? [:])
        } else {
            favorites.removeValue(forKey: filename)
            try saveToDisk()
        }

        Logger.favorites.debug("Removed favorite: \(filename, privacy: .public)")
    }

    /// 指定ファイルのお気に入りレベルを取得（未設定は0）
    /// - Parameter url: 画像のURL
    /// - Returns: お気に入りレベル（0は未設定）
    func getFavoriteLevel(for url: URL) -> Int {
        let filename = url.lastPathComponent

        if isAggregatedMode {
            // 統合モード: 画像が属するフォルダから取得
            let folderPath = url.deletingLastPathComponent().path
            // パス文字列でマッチング
            for (key, favs) in aggregatedFavorites {
                if key.path == folderPath {
                    return favs[filename] ?? 0
                }
            }
            return 0
        } else {
            return favorites[filename] ?? 0
        }
    }

    /// 全お気に入りデータを取得
    /// - Returns: ファイル名とレベルのマッピング
    func getAllFavorites() -> [String: Int] {
        return favorites
    }

    // MARK: - Aggregated Mode Methods (Subdirectory Support)

    /// 複数フォルダのお気に入りを並列読み込み
    /// - Parameter folderURLs: 読み込み対象のフォルダURL配列
    /// - Returns: フォルダURL→（ファイル名→レベル）のマッピング
    func loadAggregatedFavorites(for folderURLs: [URL]) async -> [URL: [String: Int]] {
        isAggregatedMode = true
        aggregatedFavorites = [:]

        // 並列読み込みせずシリアルに処理（actorの制約を避けるため）
        for folderURL in folderURLs {
            let favorites = loadFavoritesFromDisk(for: folderURL)
            aggregatedFavorites[folderURL] = favorites
        }

        let totalCount = aggregatedFavorites.values.reduce(0) { $0 + $1.count }
        Logger.favorites.info("Loaded aggregated favorites: \(totalCount, privacy: .public) items from \(folderURLs.count, privacy: .public) folders")

        return aggregatedFavorites
    }

    /// 統合されたお気に入りデータを取得
    /// - Returns: フォルダURL→（ファイル名→レベル）のマッピング
    func getAggregatedFavorites() -> [URL: [String: Int]] {
        return aggregatedFavorites
    }

    /// 指定レベル以上のお気に入りファイルのフルパスURLを取得
    /// - Parameter minimumLevel: 最低お気に入りレベル（1-5）
    /// - Returns: 条件を満たすファイルのURL配列（存在確認済み）
    func getFavoriteFileURLs(minimumLevel: Int) -> [URL] {
        var result: [URL] = []

        for (folderURL, favorites) in aggregatedFavorites {
            for (filename, level) in favorites where level >= minimumLevel {
                let fileURL = folderURL.appendingPathComponent(filename)
                // ファイル存在確認
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    result.append(fileURL)
                }
            }
        }

        return result
    }

    // MARK: - Private Methods

    /// 指定フォルダのfavorites.jsonをディスクから読み込み（内部用）
    private nonisolated func loadFavoritesFromDisk(for folderURL: URL) -> [String: Int] {
        let cacheDir = ".aiview"
        let filename = "favorites.json"
        let favoritesURL = folderURL
            .appendingPathComponent(cacheDir)
            .appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: favoritesURL.path) else {
            return [:]
        }

        do {
            let data = try Data(contentsOf: favoritesURL)
            return try JSONDecoder().decode([String: Int].self, from: data)
        } catch {
            Logger.favorites.warning("Failed to load favorites from \(folderURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return [:]
        }
    }

    private func favoritesFileURL(for folderURL: URL) -> URL {
        return folderURL
            .appendingPathComponent(cacheDirectoryName)
            .appendingPathComponent(favoritesFileName)
    }

    private func saveToDisk() throws {
        guard let folderURL = currentFolderURL else {
            Logger.favorites.error("No folder URL set")
            return
        }

        try saveToDisk(folderURL: folderURL, favorites: favorites)
    }

    /// 指定フォルダにお気に入りデータを保存
    private func saveToDisk(folderURL: URL, favorites: [String: Int]) throws {
        let cacheDir = folderURL.appendingPathComponent(cacheDirectoryName)

        // .aiviewフォルダを作成
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            Logger.favorites.debug("Created .aiview directory for \(folderURL.lastPathComponent, privacy: .public)")
        }

        let favoritesURL = cacheDir.appendingPathComponent(favoritesFileName)
        let data = try JSONEncoder().encode(favorites)
        try data.write(to: favoritesURL, options: .atomic)
    }
}

// MARK: - Logger Extension

extension Logger {
    /// お気に入り機能用ログカテゴリ
    static let favorites = Logger(subsystem: Bundle.main.bundleIdentifier ?? "AIview", category: "favorites")
}
