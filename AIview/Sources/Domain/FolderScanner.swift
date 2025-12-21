import Foundation
import os

/// フォルダスキャンのエラー
enum FolderScanError: Error, LocalizedError {
    case folderNotFound(URL)
    case accessDenied(URL)
    case cancelled

    var errorDescription: String? {
        switch self {
        case .folderNotFound(let url):
            return "フォルダが見つかりません: \(url.lastPathComponent)"
        case .accessDenied(let url):
            return "フォルダへのアクセス権限がありません: \(url.lastPathComponent)"
        case .cancelled:
            return "スキャンがキャンセルされました"
        }
    }
}

/// フォルダスキャナー
/// ディレクトリのストリーミング列挙と画像フィルタリング
/// Requirements: 1.2, 1.3, 7.1, 7.2, 7.3, 7.4, 10.2
actor FolderScanner {
    /// 対応する画像拡張子
    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif"]

    private var currentScanTask: Task<Void, Error>?
    private var isCancelled = false

    /// フォルダをスキャンして画像ファイルを列挙
    /// - Parameters:
    ///   - folderURL: スキャン対象のフォルダURL
    ///   - onFirstImage: 最初の画像が見つかった時のコールバック
    ///   - onProgress: 進行状況のコールバック（バッチごとのURL配列）
    ///   - onComplete: 完了時のコールバック（全URLの配列）
    func scan(
        folderURL: URL,
        onFirstImage: @Sendable (URL) async -> Void,
        onProgress: @Sendable ([URL]) async -> Void,
        onComplete: @Sendable ([URL]) async -> Void
    ) async throws {
        // 既存のスキャンをキャンセル
        currentScanTask?.cancel()
        isCancelled = false

        Logger.folderScanner.debug("Starting scan: \(folderURL.path, privacy: .public)")

        let fileManager = FileManager.default

        // フォルダの存在確認
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FolderScanError.folderNotFound(folderURL)
        }

        // アクセス権限確認
        guard fileManager.isReadableFile(atPath: folderURL.path) else {
            throw FolderScanError.accessDenied(folderURL)
        }

        // DirectoryEnumeratorでストリーミング列挙
        guard let enumerator = fileManager.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                Logger.folderScanner.warning("Error accessing \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                return true // Continue enumeration
            }
        ) else {
            throw FolderScanError.accessDenied(folderURL)
        }

        var allImageURLs: [URL] = []
        var firstImageFound = false
        let batchSize = 50

        for case let fileURL as URL in enumerator {
            // キャンセルチェック
            if isCancelled || Task.isCancelled {
                Logger.folderScanner.info("Scan cancelled")
                throw FolderScanError.cancelled
            }

            // ファイルかどうか確認
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                  resourceValues.isRegularFile == true else {
                continue
            }

            // 拡張子チェック（case-insensitive）
            let ext = fileURL.pathExtension.lowercased()
            guard Self.supportedExtensions.contains(ext) else {
                continue
            }

            allImageURLs.append(fileURL)

            // 最初の画像が見つかったら即座にコールバック
            if !firstImageFound {
                firstImageFound = true
                Logger.folderScanner.debug("First image found: \(fileURL.lastPathComponent, privacy: .public)")
                await onFirstImage(fileURL)
            }

            // バッチ処理で進行状況を報告
            if allImageURLs.count % batchSize == 0 {
                await onProgress(allImageURLs)
            }
        }

        // ファイル名でソート
        allImageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        Logger.folderScanner.info("Scan complete: found \(allImageURLs.count, privacy: .public) images")
        await onComplete(allImageURLs)
    }

    /// 現在のスキャンをキャンセル
    func cancelCurrentScan() {
        isCancelled = true
        currentScanTask?.cancel()
        Logger.folderScanner.debug("Scan cancellation requested")
    }
}
