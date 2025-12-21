import Foundation
import CryptoKit
import os

/// ディスクキャッシュストア
/// .aiviewフォルダへのサムネイル永続化
/// Requirements: 9.4-9.7
actor DiskCacheStore {
    private let baseURL: URL?
    private let cacheDirectoryName = ".aiview"
    private let fileManager = FileManager.default

    init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    /// サムネイルをディスクから取得
    /// - Parameters:
    ///   - originalURL: 元画像のURL
    ///   - thumbnailSize: サムネイルサイズ
    ///   - modificationDate: 元画像の更新日時
    /// - Returns: サムネイルデータ（存在しない場合はnil）
    func getThumbnail(
        originalURL: URL,
        thumbnailSize: CGSize,
        modificationDate: Date
    ) async -> Data? {
        let cacheURL = thumbnailCacheURL(
            for: originalURL,
            size: thumbnailSize,
            modificationDate: modificationDate
        )

        guard fileManager.fileExists(atPath: cacheURL.path) else {
            return nil
        }

        do {
            let data = try Data(contentsOf: cacheURL)
            Logger.cacheManager.debug("Disk cache hit: \(cacheURL.lastPathComponent, privacy: .public)")
            return data
        } catch {
            Logger.cacheManager.warning("Failed to read disk cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// サムネイルをディスクに保存
    /// - Parameters:
    ///   - data: サムネイルデータ（JPEG）
    ///   - originalURL: 元画像のURL
    ///   - thumbnailSize: サムネイルサイズ
    ///   - modificationDate: 元画像の更新日時
    func storeThumbnail(
        _ data: Data,
        originalURL: URL,
        thumbnailSize: CGSize,
        modificationDate: Date
    ) async throws {
        let cacheURL = thumbnailCacheURL(
            for: originalURL,
            size: thumbnailSize,
            modificationDate: modificationDate
        )

        // .aiviewフォルダを作成
        let cacheDirectory = cacheURL.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: cacheDirectory.path) {
            do {
                try fileManager.createDirectory(
                    at: cacheDirectory,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
                Logger.cacheManager.debug("Created cache directory: \(cacheDirectory.path, privacy: .public)")
            } catch {
                Logger.cacheManager.error("Failed to create cache directory: \(error.localizedDescription, privacy: .public)")
                throw error
            }
        }

        // サムネイルを保存
        do {
            try data.write(to: cacheURL, options: .atomic)
            Logger.cacheManager.debug("Stored thumbnail: \(cacheURL.lastPathComponent, privacy: .public)")
        } catch {
            Logger.cacheManager.error("Failed to store thumbnail: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// 指定フォルダのキャッシュをクリア
    /// - Parameter folderURL: 対象フォルダのURL
    func clearCache(for folderURL: URL) async throws {
        let cacheDirectory = cacheDirectoryURL(for: folderURL)

        guard fileManager.fileExists(atPath: cacheDirectory.path) else {
            return
        }

        do {
            try fileManager.removeItem(at: cacheDirectory)
            Logger.cacheManager.info("Cleared cache for: \(folderURL.lastPathComponent, privacy: .public)")
        } catch {
            Logger.cacheManager.error("Failed to clear cache: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    // MARK: - Private Methods

    private func cacheDirectoryURL(for folderURL: URL) -> URL {
        if let baseURL = baseURL {
            return baseURL.appendingPathComponent(cacheDirectoryName)
        }
        return folderURL.appendingPathComponent(cacheDirectoryName)
    }

    private func thumbnailCacheURL(
        for originalURL: URL,
        size: CGSize,
        modificationDate: Date
    ) -> URL {
        let folderURL = originalURL.deletingLastPathComponent()
        let cacheDirectory = cacheDirectoryURL(for: folderURL)

        // キャッシュファイル名: <sha256(originalPath)>_<modDate>_<width>x<height>.jpg
        let pathHash = sha256Hash(of: originalURL.path)
        let modDateString = formattedModificationDate(modificationDate)
        let sizeString = "\(Int(size.width))x\(Int(size.height))"
        let fileName = "\(pathHash)_\(modDateString)_\(sizeString).jpg"

        return cacheDirectory.appendingPathComponent(fileName)
    }

    private func sha256Hash(of string: String) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private func formattedModificationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }
}
