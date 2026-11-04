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
actor FavoritesStore: FavoritesStoring {
    /// お気に入りデータのファイル名
    private let favoritesFileName = "favorites.json"

    /// キャッシュディレクトリ名
    private let cacheDirectoryName = ".aiview"

    /// 現在のフォルダURL
    private var currentFolderURL: URL?

    /// メモリ上のお気に入りデータ。通常/統合モードとも source はこの1個だけ。
    private var favoriteLevelsByURL: [URL: Int] = [:]

    /// 現在 snapshot に含まれるフォルダ。互換 API の nested dictionary 再構築に使う。
    private var loadedFolderURLs: [URL] = []

    /// 現在フォルダの「最後に表示していた画像」ファイル名（非統合モードのみ有効）
    private var lastViewedImage: String?

    /// 現在統合モードかどうか
    private var isAggregatedMode: Bool = false

    private let fileManager = FileManager.default

    // MARK: - Public Methods

    /// 指定フォルダのお気に入りを読み込み（統合モードを解除）
    /// - Parameter folderURL: 対象フォルダのURL
    func loadFavorites(for folderURL: URL) {
        _ = loadSnapshot(for: folderURL)
    }

    /// 単一フォルダを完全 URL key の snapshot として読み込む。
    func loadSnapshot(for folderURL: URL) -> FavoriteFolderSnapshot {
        let normalizedFolder = FavoriteURLKey.normalize(folderURL)
        currentFolderURL = normalizedFolder
        isAggregatedMode = false
        loadedFolderURLs = [normalizedFolder]

        let favoritesURL = favoritesFileURL(for: normalizedFolder)
        let file: FavoritesFile
        if fileManager.fileExists(atPath: favoritesURL.path) {
            file = Self.loadFile(at: favoritesURL)
        } else {
            Logger.favorites.debug("No favorites file found, starting fresh")
            file = FavoritesFile()
        }

        favoriteLevelsByURL = FavoriteURLKey.snapshot(
            folderURL: normalizedFolder,
            favorites: file.favorites
        )
        lastViewedImage = file.lastViewedImage
        Logger.favorites.info("Loaded \(self.favoriteLevelsByURL.count, privacy: .public) favorites")
        return FavoriteFolderSnapshot(
            levelsByURL: favoriteLevelsByURL,
            lastViewedImage: lastViewedImage
        )
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

        let key = FavoriteURLKey.normalize(url)
        let folderURL = FavoriteURLKey.normalize(key.deletingLastPathComponent())
        let filename = key.lastPathComponent
        var candidate = favoriteCandidateForFolder(folderURL)
        candidate[filename] = level

        // disk 成功を transaction の境界にし、成功前は memory snapshot を変更しない。
        try saveToDisk(folderURL: folderURL, favorites: candidate)
        favoriteLevelsByURL[key] = level
        appendLoadedFolderIfNeeded(folderURL)

        Logger.favorites.debug("Set favorite: \(filename, privacy: .private) = \(level, privacy: .public)")
    }

    /// お気に入りを解除
    /// - Parameter url: 画像のURL
    func removeFavorite(for url: URL) throws {
        let key = FavoriteURLKey.normalize(url)
        let folderURL = FavoriteURLKey.normalize(key.deletingLastPathComponent())
        let filename = key.lastPathComponent
        var candidate = favoriteCandidateForFolder(folderURL)
        candidate.removeValue(forKey: filename)

        // disk 成功を transaction の境界にし、成功前は memory snapshot を変更しない。
        try saveToDisk(folderURL: folderURL, favorites: candidate)
        favoriteLevelsByURL.removeValue(forKey: key)
        appendLoadedFolderIfNeeded(folderURL)

        Logger.favorites.debug("Removed favorite: \(filename, privacy: .private)")
    }

    /// 指定ファイルのお気に入りレベルを取得（未設定は0）
    /// - Parameter url: 画像のURL
    /// - Returns: お気に入りレベル（0は未設定）
    func getFavoriteLevel(for url: URL) -> Int {
        favoriteLevelsByURL[FavoriteURLKey.normalize(url)] ?? 0
    }

    /// 全お気に入りデータを取得
    /// - Returns: ファイル名とレベルのマッピング
    func getAllFavorites() -> [String: Int] {
        guard let currentFolderURL else { return [:] }
        return favoritesForFolder(currentFolderURL)
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
        let normalizedFolder = FavoriteURLKey.normalize(folderURL)
        guard let currentFolderURL, currentFolderURL == normalizedFolder else {
            Logger.favorites.debug("setLastViewedImage skipped: folder mismatch")
            return
        }

        do {
            // privacy mode は owner Task を cancel する。actor 待機中に cancel された場合も
            // disk commit 直前で破棄する。
            guard !Task.isCancelled else { return }
            let file = FavoritesFile(
                favorites: favoritesForFolder(normalizedFolder),
                lastViewedImage: filename
            )
            guard !Task.isCancelled else { return }
            try writeFile(file, to: normalizedFolder)
            lastViewedImage = filename
            Logger.favorites.debug("Recorded last-viewed image")
        } catch {
            Logger.favorites.warning("Failed to record last-viewed image: \(error.localizedDescription, privacy: .private)")
        }
    }

    // MARK: - Aggregated Mode Methods (Subdirectory Support)

    /// 複数フォルダのお気に入りを並列読み込み
    /// - Parameter folderURLs: 読み込み対象のフォルダURL配列
    /// - Returns: フォルダURL→（ファイル名→レベル）のマッピング
    func loadAggregatedFavorites(for folderURLs: [URL]) async -> [URL: [String: Int]] {
        _ = loadSnapshot(for: folderURLs)
        let aggregatedFavorites = getAggregatedFavorites()
        let totalCount = favoriteLevelsByURL.count
        Logger.favorites.info("Loaded aggregated favorites: \(totalCount, privacy: .public) items from \(folderURLs.count, privacy: .public) folders")

        return aggregatedFavorites
    }

    /// 複数フォルダのお気に入りを完全 URL key の単一 snapshot に読み込む。
    func loadSnapshot(for folderURLs: [URL]) -> [URL: Int] {
        isAggregatedMode = true
        lastViewedImage = nil
        var seenFolders: Set<URL> = []
        loadedFolderURLs = folderURLs
            .map(FavoriteURLKey.normalize)
            .filter { seenFolders.insert($0).inserted }
        favoriteLevelsByURL = [:]

        for folderURL in loadedFolderURLs {
            let favorites = loadFavoritesFromDisk(for: folderURL)
            favoriteLevelsByURL.merge(
                FavoriteURLKey.snapshot(folderURL: folderURL, favorites: favorites),
                uniquingKeysWith: { _, new in new }
            )
        }
        return favoriteLevelsByURL
    }

    /// 統合されたお気に入りデータを取得
    /// - Returns: フォルダURL→（ファイル名→レベル）のマッピング
    func getAggregatedFavorites() -> [URL: [String: Int]] {
        loadedFolderURLs.reduce(into: [:]) { result, folderURL in
            result[folderURL] = favoritesForFolder(folderURL)
        }
    }

    /// 指定レベル以上のお気に入りファイルのフルパスURLを取得
    /// - Parameter minimumLevel: 最低お気に入りレベル（1-5）
    /// - Returns: 条件を満たすファイルのURL配列（存在確認済み）
    func getFavoriteFileURLs(minimumLevel: Int) -> [URL] {
        favoriteLevelsByURL.compactMap { url, level in
            guard level >= minimumLevel,
                  FileManager.default.fileExists(atPath: url.path) else { return nil }
            return url
        }
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

    private func favoritesForFolder(_ folderURL: URL) -> [String: Int] {
        let normalizedFolder = FavoriteURLKey.normalize(folderURL)
        return favoriteLevelsByURL.reduce(into: [:]) { result, entry in
            let entryFolder = FavoriteURLKey.normalize(entry.key.deletingLastPathComponent())
            if entryFolder == normalizedFolder {
                result[entry.key.lastPathComponent] = entry.value
            }
        }
    }

    private func favoriteCandidateForFolder(_ folderURL: URL) -> [String: Int] {
        let normalizedFolder = FavoriteURLKey.normalize(folderURL)
        if loadedFolderURLs.contains(normalizedFolder) {
            return favoritesForFolder(normalizedFolder)
        }
        return loadFavoritesFromDisk(for: normalizedFolder)
    }

    private func appendLoadedFolderIfNeeded(_ folderURL: URL) {
        let normalizedFolder = FavoriteURLKey.normalize(folderURL)
        if !loadedFolderURLs.contains(normalizedFolder) {
            loadedFolderURLs.append(normalizedFolder)
        }
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
            Logger.favorites.warning("Failed to load favorites file: \(error.localizedDescription, privacy: .private)")
            return FavoritesFile()
        }
    }

    private func favoritesFileURL(for folderURL: URL) -> URL {
        return folderURL
            .appendingPathComponent(cacheDirectoryName)
            .appendingPathComponent(favoritesFileName)
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
            Logger.favorites.debug("Created .aiview directory")
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
