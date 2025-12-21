import Foundation
import os

/// ファイルシステム操作のエラー
enum FileSystemError: Error, LocalizedError {
    case fileNotFound(URL)
    case accessDenied(URL)
    case deleteFailed(URL, underlying: Error)
    case attributeReadFailed(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "ファイルが見つかりません: \(url.lastPathComponent)"
        case .accessDenied(let url):
            return "アクセス権限がありません: \(url.lastPathComponent)"
        case .deleteFailed(let url, let underlying):
            return "削除に失敗しました: \(url.lastPathComponent) (\(underlying.localizedDescription))"
        case .attributeReadFailed(let url, let underlying):
            return "属性の読み取りに失敗しました: \(url.lastPathComponent) (\(underlying.localizedDescription))"
        }
    }
}

/// ファイル属性
struct FileAttributes: Sendable {
    let size: Int64
    let modificationDate: Date
    let creationDate: Date?
}

/// ファイルシステムアクセスのプロトコル
protocol FileSystemAccessProtocol: Sendable {
    func moveToTrash(_ url: URL) async throws
    func checkAccess(to url: URL) -> Bool
    func getFileAttributes(_ url: URL) throws -> FileAttributes
}

/// ファイルシステムアクセスの実装
/// Requirements: 4.1, 4.2, 4.3, 4.4, 11.2
final class FileSystemAccess: FileSystemAccessProtocol, @unchecked Sendable {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// ファイルをゴミ箱に移動する（ゴミ箱がない場合は直接削除）
    /// - Parameter url: 削除するファイルのURL
    /// - Throws: FileSystemError
    func moveToTrash(_ url: URL) async throws {
        Logger.fileSystem.debug("Moving to trash: \(url.path, privacy: .public)")

        guard fileManager.fileExists(atPath: url.path) else {
            Logger.fileSystem.error("File not found for trash: \(url.path, privacy: .public)")
            throw FileSystemError.fileNotFound(url)
        }

        do {
            var resultingURL: NSURL?
            try fileManager.trashItem(at: url, resultingItemURL: &resultingURL)
            Logger.fileSystem.info("Successfully moved to trash: \(url.lastPathComponent, privacy: .public)")
        } catch let trashError as NSError where trashError.domain == NSCocoaErrorDomain && trashError.code == NSFeatureUnsupportedError {
            // ゴミ箱がないボリューム（外部ドライブ等）の場合、直接削除にフォールバック
            Logger.fileSystem.warning("Trash not available, falling back to direct delete: \(url.lastPathComponent, privacy: .public)")
            do {
                try fileManager.removeItem(at: url)
                Logger.fileSystem.info("Successfully deleted (direct): \(url.lastPathComponent, privacy: .public)")
            } catch {
                Logger.fileSystem.error("Failed to delete: \(error.localizedDescription, privacy: .public)")
                throw FileSystemError.deleteFailed(url, underlying: error)
            }
        } catch {
            Logger.fileSystem.error("Failed to move to trash: \(error.localizedDescription, privacy: .public)")
            throw FileSystemError.deleteFailed(url, underlying: error)
        }
    }

    /// ファイルまたはディレクトリへのアクセス権限を確認する
    /// - Parameter url: 確認するファイル/ディレクトリのURL
    /// - Returns: アクセス可能な場合はtrue
    func checkAccess(to url: URL) -> Bool {
        let exists = fileManager.fileExists(atPath: url.path)
        if exists {
            return fileManager.isReadableFile(atPath: url.path)
        }
        return false
    }

    /// ファイル属性を取得する
    /// - Parameter url: ファイルのURL
    /// - Returns: FileAttributes
    /// - Throws: FileSystemError
    func getFileAttributes(_ url: URL) throws -> FileAttributes {
        guard fileManager.fileExists(atPath: url.path) else {
            throw FileSystemError.fileNotFound(url)
        }

        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)

            let size = (attributes[.size] as? Int64) ?? 0
            let modificationDate = (attributes[.modificationDate] as? Date) ?? Date()
            let creationDate = attributes[.creationDate] as? Date

            return FileAttributes(
                size: size,
                modificationDate: modificationDate,
                creationDate: creationDate
            )
        } catch {
            throw FileSystemError.attributeReadFailed(url, underlying: error)
        }
    }
}
