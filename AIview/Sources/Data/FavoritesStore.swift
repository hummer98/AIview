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

    private let fileManager = FileManager.default

    // MARK: - Public Methods

    /// 指定フォルダのお気に入りを読み込み
    /// - Parameter folderURL: 対象フォルダのURL
    func loadFavorites(for folderURL: URL) {
        currentFolderURL = folderURL
        favorites = [:]

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
        favorites[filename] = level

        try saveToDisk()
        Logger.favorites.debug("Set favorite: \(filename, privacy: .public) = \(level, privacy: .public)")
    }

    /// お気に入りを解除
    /// - Parameter url: 画像のURL
    func removeFavorite(for url: URL) throws {
        let filename = url.lastPathComponent
        favorites.removeValue(forKey: filename)

        try saveToDisk()
        Logger.favorites.debug("Removed favorite: \(filename, privacy: .public)")
    }

    /// 指定ファイルのお気に入りレベルを取得（未設定は0）
    /// - Parameter url: 画像のURL
    /// - Returns: お気に入りレベル（0は未設定）
    func getFavoriteLevel(for url: URL) -> Int {
        let filename = url.lastPathComponent
        return favorites[filename] ?? 0
    }

    /// 全お気に入りデータを取得
    /// - Returns: ファイル名とレベルのマッピング
    func getAllFavorites() -> [String: Int] {
        return favorites
    }

    // MARK: - Private Methods

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

        let cacheDir = folderURL.appendingPathComponent(cacheDirectoryName)

        // .aiviewフォルダを作成
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            Logger.favorites.debug("Created .aiview directory")
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
