import Foundation
import os

/// `favorites.json` の v2 ラッパー形式（ADR 001）。
/// お気に入り（ファイル名→レベル）と「最後に表示していた画像」を同居させる。
/// - `favorites` は非 optional（空は `[:]`）。
/// - `lastViewedImage` は optional（未記録は nil）。
/// - 保存は常に v2。読込は v2 を試行し、失敗で legacy `[String: Int]` に fallback する。
struct FavoritesFile: Codable {
    var favorites: [String: Int]
    var lastViewedImage: String?

    init(favorites: [String: Int] = [:], lastViewedImage: String? = nil) {
        self.favorites = favorites
        self.lastViewedImage = lastViewedImage
    }
}

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

    /// 現在フォルダの「最後に表示していた画像」ファイル名（非統合モードのみ有効）
    private var lastViewedImage: String?

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
        lastViewedImage = nil

        // 統合モードを解除
        isAggregatedMode = false
        aggregatedFavorites = [:]

        let favoritesURL = favoritesFileURL(for: folderURL)

        guard fileManager.fileExists(atPath: favoritesURL.path) else {
            Logger.favorites.debug("No favorites file found, starting fresh")
            return
        }

        let file = Self.loadFile(at: favoritesURL)
        favorites = file.favorites
        lastViewedImage = file.lastViewedImage
        Logger.favorites.info("Loaded \(self.favorites.count, privacy: .public) favorites")
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

    // MARK: - Last Viewed Image

    /// 現在フォルダの「最後に表示していた画像」ファイル名を取得
    /// - Returns: 記録があればファイル名、無ければ nil
    func getLastViewedImage() -> String? {
        return lastViewedImage
    }

    /// 「最後に表示していた画像」を記録する（非統合モードのみ）。
    /// - Parameters:
    ///   - filename: 記録するファイル名
    ///   - folderURL: 記録対象フォルダ URL（actor 内で `currentFolderURL` と一致する時のみ書く）
    /// - Note: デバウンス済みの遅延記録が、フォルダ切替後に旧フォルダのファイル名を
    ///   新フォルダへ書き込むのを防ぐため、対象フォルダ URL を引数で受けて二重チェックする（S2）。
    func setLastViewedImage(_ filename: String, for folderURL: URL) {
        // 統合モードでは記録しない（スコープ外）
        guard !isAggregatedMode else { return }

        // 記録対象フォルダが現在フォルダと一致しなければ破棄（古いフォルダ向け遅延書込を弾く）
        guard let currentFolderURL, currentFolderURL.path == folderURL.path else {
            Logger.favorites.debug("setLastViewedImage skipped: folder mismatch")
            return
        }

        lastViewedImage = filename
        do {
            try saveToDisk()
            Logger.favorites.debug("Recorded lastViewedImage: \(filename, privacy: .public)")
        } catch {
            Logger.favorites.warning("Failed to record lastViewedImage: \(error.localizedDescription, privacy: .public)")
        }
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

    /// 指定フォルダのfavorites.jsonをディスクから読み込み（内部用・統合モード）
    private nonisolated func loadFavoritesFromDisk(for folderURL: URL) -> [String: Int] {
        let cacheDir = ".aiview"
        let filename = "favorites.json"
        let favoritesURL = folderURL
            .appendingPathComponent(cacheDir)
            .appendingPathComponent(filename)

        guard FileManager.default.fileExists(atPath: favoritesURL.path) else {
            return [:]
        }

        return Self.loadFile(at: favoritesURL).favorites
    }

    /// favorites.json を v2 / legacy 両形式から読み込む共通ロジック（ADR 001）。
    /// まず v2 (`FavoritesFile`) としてデコードを試み、失敗したら legacy `[String: Int]` として
    /// 読み `favorites` に充てる（`lastViewedImage` は nil）。
    /// 病的ケース（空 `{}`、`{"favorites": 1}` のように値が Int の legacy）も安全に legacy 経路へ落ちる。
    /// - Parameter favoritesURL: `.aiview/favorites.json` の URL（存在前提）
    /// - Returns: 読み込んだ `FavoritesFile`（失敗時は空）
    static func loadFile(at favoritesURL: URL) -> FavoritesFile {
        do {
            let data = try Data(contentsOf: favoritesURL)
            if let file = try? JSONDecoder().decode(FavoritesFile.self, from: data) {
                return file
            }
            // legacy: 素の [String: Int]
            let legacy = try JSONDecoder().decode([String: Int].self, from: data)
            return FavoritesFile(favorites: legacy, lastViewedImage: nil)
        } catch {
            Logger.favorites.warning("Failed to load favorites file: \(error.localizedDescription, privacy: .public)")
            return FavoritesFile()
        }
    }

    private func favoritesFileURL(for folderURL: URL) -> URL {
        return folderURL
            .appendingPathComponent(cacheDirectoryName)
            .appendingPathComponent(favoritesFileName)
    }

    /// 現在フォルダ（非統合モード）の favorites + lastViewedImage を v2 で保存
    private func saveToDisk() throws {
        guard let folderURL = currentFolderURL else {
            Logger.favorites.error("No folder URL set")
            return
        }

        let file = FavoritesFile(favorites: favorites, lastViewedImage: lastViewedImage)
        try writeFile(file, to: folderURL)
    }

    /// 指定フォルダにお気に入りデータを保存（統合モード用）。
    /// 既存ファイルの `lastViewedImage` を read-modify-write で保全する（ADR 001）。
    private func saveToDisk(folderURL: URL, favorites: [String: Int]) throws {
        // 既存の lastViewedImage を読み出して保つ（お気に入り編集で前回位置を消さない）
        let favoritesURL = favoritesFileURL(for: folderURL)
        let existingLastViewed: String? = fileManager.fileExists(atPath: favoritesURL.path)
            ? Self.loadFile(at: favoritesURL).lastViewedImage
            : nil

        let file = FavoritesFile(favorites: favorites, lastViewedImage: existingLastViewed)
        try writeFile(file, to: folderURL)
    }

    /// v2 形式の `FavoritesFile` を `.aiview/favorites.json` へ atomic 保存する共通処理
    private func writeFile(_ file: FavoritesFile, to folderURL: URL) throws {
        let cacheDir = folderURL.appendingPathComponent(cacheDirectoryName)

        // .aiviewフォルダを作成
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
            Logger.favorites.debug("Created .aiview directory for \(folderURL.lastPathComponent, privacy: .public)")
        }

        let favoritesURL = cacheDir.appendingPathComponent(favoritesFileName)
        let data = try JSONEncoder().encode(file)
        try data.write(to: favoritesURL, options: .atomic)
    }
}

// MARK: - Logger Extension

extension Logger {
    /// お気に入り機能用ログカテゴリ
    static let favorites = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.ridgeroot.AIview", category: "favorites")
}
