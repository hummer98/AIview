import Foundation
import os

/// フォルダスキャン中に順次通知されるイベント。
enum FolderScanEvent: Equatable, Sendable {
    case first(URL)
    case progress([URL])
    case complete([URL])
}

/// サブディレクトリスキャン結果。
struct SubdirectoryScanResult: Sendable {
    let imageURLs: [URL]
    let subdirectoryURLs: [URL]
}

/// ViewModelから注入可能なFolderScanner境界。
protocol FolderScanning: Sendable {
    func scan(folderURL: URL) async -> AsyncThrowingStream<FolderScanEvent, Error>
    func scanWithSubdirectories(folderURL: URL) async throws -> SubdirectoryScanResult
}

/// フォルダスキャンのエラー。
enum FolderScanError: Error, LocalizedError, Sendable {
    case folderNotFound(URL)
    case accessDenied(URL)

    var errorDescription: String? {
        switch self {
        case .folderNotFound(let url):
            return "フォルダが見つかりません: \(url.lastPathComponent)"
        case .accessDenied(let url):
            return "フォルダへのアクセス権限がありません: \(url.lastPathComponent)"
        }
    }
}

/// ディレクトリのストリーミング列挙と画像フィルタリング。
/// 各streamが自身の列挙Taskを所有し、consumer終了時にのみそのTaskをcancelする。
actor FolderScanner: FolderScanning {
    typealias EntryCheckpoint = @Sendable (URL) async -> Void

    static let supportedExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "webp", "gif"]

    private let beforeProcessingEntry: EntryCheckpoint
    private let batchSize: Int

    init(
        batchSize: Int = 50,
        beforeProcessingEntry: @escaping EntryCheckpoint = { _ in }
    ) {
        self.batchSize = max(1, batchSize)
        self.beforeProcessingEntry = beforeProcessingEntry
    }

    /// フォルダ直下を列挙するstreamを生成する。
    /// streamのtermination handlerが、このstream専用の列挙Taskをcancelする。
    func scan(folderURL: URL) -> AsyncThrowingStream<FolderScanEvent, Error> {
        let checkpoint = beforeProcessingEntry
        let batchSize = batchSize

        return AsyncThrowingStream { continuation in
            let enumerationTask = Task(priority: .utility) {
                do {
                    try Self.validateFolder(folderURL)
                    Logger.folderScanner.debug("Starting scan: \(folderURL.path, privacy: .private)")

                    let urls = try await Self.enumerateImages(
                        in: [folderURL],
                        batchSize: batchSize,
                        beforeProcessingEntry: checkpoint,
                        continuation: continuation
                    )
                    try Self.yield(.complete(urls), to: continuation)
                    continuation.finish()
                    Logger.folderScanner.info("Scan complete: found \(urls.count, privacy: .public) images")
                } catch is CancellationError {
                    continuation.finish(throwing: CancellationError())
                    Logger.folderScanner.debug("Scan cancelled")
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                enumerationTask.cancel()
            }
        }
    }

    /// 親フォルダと1階層下のサブディレクトリを一括取得する。
    /// 呼び出し元Taskのcancellationだけに従い、別scanと状態を共有しない。
    func scanWithSubdirectories(folderURL: URL) async throws -> SubdirectoryScanResult {
        try Self.validateFolder(folderURL)
        try Task.checkCancellation()

        let fileManager = FileManager.default
        let contents = (try? fileManager.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var subdirectories: [URL] = []
        for itemURL in contents {
            try Task.checkCancellation()
            let values = try? itemURL.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true {
                subdirectories.append(itemURL)
            }
        }
        subdirectories.sort(by: Self.compareByFilename)

        let urls = try await Self.enumerateImages(
            in: [folderURL] + subdirectories,
            beforeProcessingEntry: beforeProcessingEntry
        )

        Logger.folderScanner.info(
            "Subdirectory scan complete: found \(urls.count, privacy: .public) images in \(subdirectories.count + 1, privacy: .public) folders"
        )
        return SubdirectoryScanResult(imageURLs: urls, subdirectoryURLs: subdirectories)
    }

    private nonisolated static func validateFolder(_ folderURL: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw FolderScanError.folderNotFound(folderURL)
        }
        guard fileManager.isReadableFile(atPath: folderURL.path) else {
            throw FolderScanError.accessDenied(folderURL)
        }
    }

    private nonisolated static func enumerateImages(
        in folders: [URL],
        beforeProcessingEntry: EntryCheckpoint
    ) async throws -> [URL] {
        var allImageURLs: [URL] = []
        for folderURL in folders {
            try Task.checkCancellation()
            guard let enumerator = makeEnumerator(for: folderURL) else {
                throw FolderScanError.accessDenied(folderURL)
            }

            while let fileURL = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                await beforeProcessingEntry(fileURL)
                try Task.checkCancellation()
                if isSupportedImage(fileURL) {
                    allImageURLs.append(fileURL)
                }
            }
        }
        return allImageURLs.sorted(by: compareByFilename)
    }

    private nonisolated static func enumerateImages(
        in folders: [URL],
        batchSize: Int,
        beforeProcessingEntry: EntryCheckpoint,
        continuation: AsyncThrowingStream<FolderScanEvent, Error>.Continuation
    ) async throws -> [URL] {
        var allImageURLs: [URL] = []
        var didYieldFirst = false

        for folderURL in folders {
            try Task.checkCancellation()
            guard let enumerator = makeEnumerator(for: folderURL) else {
                throw FolderScanError.accessDenied(folderURL)
            }

            while let fileURL = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                await beforeProcessingEntry(fileURL)
                try Task.checkCancellation()
                guard isSupportedImage(fileURL) else { continue }

                allImageURLs.append(fileURL)
                if !didYieldFirst {
                    didYieldFirst = true
                    try yield(.first(fileURL), to: continuation)
                }
                if allImageURLs.count.isMultiple(of: batchSize) {
                    try yield(.progress(allImageURLs), to: continuation)
                }
            }
        }

        return allImageURLs.sorted(by: compareByFilename)
    }

    private nonisolated static func makeEnumerator(for folderURL: URL) -> FileManager.DirectoryEnumerator? {
        FileManager.default.enumerator(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                Logger.folderScanner.warning(
                    "Directory enumeration error: path=\(url.path, privacy: .private) detail=\(error.localizedDescription, privacy: .private)"
                )
                return true
            }
        )
    }

    private nonisolated static func isSupportedImage(_ fileURL: URL) -> Bool {
        guard let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true else {
            return false
        }
        return supportedExtensions.contains(fileURL.pathExtension.lowercased())
    }

    private nonisolated static func compareByFilename(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.lastPathComponent.localizedStandardCompare(rhs.lastPathComponent) == .orderedAscending
    }

    private nonisolated static func yield(
        _ event: FolderScanEvent,
        to continuation: AsyncThrowingStream<FolderScanEvent, Error>.Continuation
    ) throws {
        switch continuation.yield(event) {
        case .enqueued, .dropped:
            return
        case .terminated:
            throw CancellationError()
        @unknown default:
            throw CancellationError()
        }
    }
}
