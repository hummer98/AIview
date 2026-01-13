import Foundation
import os

/// サブディレクトリスキャン結果
/// コールバックではなく直接戻り値として結果を返すための構造体
struct SubdirectoryScanResult: Sendable {
    /// 発見された画像URLのリスト（ソート済み）
    let imageURLs: [URL]
    /// 発見されたサブディレクトリURLのリスト
    let subdirectoryURLs: [URL]
}

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

    /// サブディレクトリを含むスキャン
    /// - Parameters:
    ///   - folderURL: スキャン対象の親フォルダURL
    ///   - includeSubdirectories: サブディレクトリを含めるか（1階層のみ）
    ///   - onFirstImage: 最初の画像が見つかった時のコールバック
    ///   - onProgress: 進行状況のコールバック
    ///   - onComplete: 完了時のコールバック（全URLの配列）
    ///   - onSubdirectories: 発見したサブディレクトリURLのコールバック
    func scan(
        folderURL: URL,
        includeSubdirectories: Bool,
        onFirstImage: @Sendable (URL) async -> Void,
        onProgress: @Sendable ([URL]) async -> Void,
        onComplete: @Sendable ([URL]) async -> Void,
        onSubdirectories: @Sendable ([URL]) async -> Void
    ) async throws {
        // includeSubdirectories=falseの場合は既存メソッドに委譲
        if !includeSubdirectories {
            // onSubdirectoriesに空配列を渡す
            await onSubdirectories([])
            try await scan(
                folderURL: folderURL,
                onFirstImage: onFirstImage,
                onProgress: onProgress,
                onComplete: onComplete
            )
            return
        }

        // 既存のスキャンをキャンセル
        currentScanTask?.cancel()
        isCancelled = false

        Logger.folderScanner.debug("Starting subdirectory scan: \(folderURL.path, privacy: .public)")

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

        // まず親フォルダのサブディレクトリを取得
        var subdirectories: [URL] = []
        if let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for itemURL in contents {
                guard let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
                      resourceValues.isDirectory == true else {
                    continue
                }
                subdirectories.append(itemURL)
            }
        }

        // サブディレクトリを通知
        await onSubdirectories(subdirectories)

        // 探索対象フォルダ（親 + サブディレクトリ）
        let foldersToScan = [folderURL] + subdirectories

        var allImageURLs: [URL] = []
        var firstImageFound = false
        let batchSize = 50

        // 各フォルダを順番にスキャン
        for folder in foldersToScan {
            // キャンセルチェック
            if isCancelled || Task.isCancelled {
                Logger.folderScanner.info("Subdirectory scan cancelled")
                throw FolderScanError.cancelled
            }

            // DirectoryEnumeratorでストリーミング列挙（サブディレクトリは含めない）
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { url, error in
                    Logger.folderScanner.warning("Error accessing \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return true // Continue enumeration
                }
            ) else {
                Logger.folderScanner.warning("Cannot access: \(folder.path, privacy: .public)")
                continue
            }

            for case let fileURL as URL in enumerator {
                // キャンセルチェック
                if isCancelled || Task.isCancelled {
                    Logger.folderScanner.info("Subdirectory scan cancelled")
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
                    Logger.folderScanner.debug("First image found (subdirectory scan): \(fileURL.lastPathComponent, privacy: .public)")
                    await onFirstImage(fileURL)
                }

                // バッチ処理で進行状況を報告
                if allImageURLs.count % batchSize == 0 {
                    await onProgress(allImageURLs)
                }
            }
        }

        // ファイル名でソート
        allImageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        Logger.folderScanner.info("Subdirectory scan complete: found \(allImageURLs.count, privacy: .public) images in \(foldersToScan.count, privacy: .public) folders")
        await onComplete(allImageURLs)
    }

    /// サブディレクトリを含むスキャン（結果を直接返す版）
    /// コールバックを使用せず、結果を直接返すことでレースコンディションを回避
    /// - Parameter folderURL: スキャン対象の親フォルダURL
    /// - Returns: スキャン結果（画像URLとサブディレクトリURL）
    func scanWithSubdirectories(folderURL: URL) async throws -> SubdirectoryScanResult {
        // 既存のスキャンをキャンセル
        currentScanTask?.cancel()
        isCancelled = false

        Logger.folderScanner.debug("Starting subdirectory scan (direct return): \(folderURL.path, privacy: .public)")

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

        // 親フォルダのサブディレクトリを取得
        var subdirectories: [URL] = []
        if let contents = try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for itemURL in contents {
                guard let resourceValues = try? itemURL.resourceValues(forKeys: [.isDirectoryKey]),
                      resourceValues.isDirectory == true else {
                    continue
                }
                subdirectories.append(itemURL)
            }
        }

        // 探索対象フォルダ（親 + サブディレクトリ）
        let foldersToScan = [folderURL] + subdirectories

        var allImageURLs: [URL] = []

        // 各フォルダを順番にスキャン
        for folder in foldersToScan {
            // キャンセルチェック
            if isCancelled || Task.isCancelled {
                Logger.folderScanner.info("Subdirectory scan cancelled")
                throw FolderScanError.cancelled
            }

            // DirectoryEnumeratorでストリーミング列挙（サブディレクトリは含めない）
            guard let enumerator = fileManager.enumerator(
                at: folder,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
                errorHandler: { url, error in
                    Logger.folderScanner.warning("Error accessing \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return true // Continue enumeration
                }
            ) else {
                Logger.folderScanner.warning("Cannot access: \(folder.path, privacy: .public)")
                continue
            }

            for case let fileURL as URL in enumerator {
                // キャンセルチェック
                if isCancelled || Task.isCancelled {
                    Logger.folderScanner.info("Subdirectory scan cancelled")
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
            }
        }

        // ファイル名でソート
        allImageURLs.sort { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

        Logger.folderScanner.info("Subdirectory scan complete (direct return): found \(allImageURLs.count, privacy: .public) images in \(foldersToScan.count, privacy: .public) folders")

        return SubdirectoryScanResult(imageURLs: allImageURLs, subdirectoryURLs: subdirectories)
    }
}
