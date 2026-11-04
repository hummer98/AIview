import Foundation
import Darwin
import os

/// ユーザー操作の失敗を、UI と診断で共有する privacy-safe な分類へ変換する。
///
/// URL、ファイル名、prompt、metadata、underlying error は保持しない。下位層の error は
/// presentation 境界で一度だけこの型へ写像し、詳細を必要とする診断は private OSLog に分離する。
enum AppError: Error, Equatable, Sendable {
    enum Operation: String, Equatable, Sendable {
        case folderSelection
        case openPath
        case scanFolder
        case reloadFolder
        case loadImage
        case saveFavorite
        case deleteImage
        case cacheWrite
        case metadataRead
        case deleteTelemetryIdentifier
    }

    enum Category: String, Equatable, Sendable {
        case userCancelled
        case permission
        case persistence
        case decode
        case invariant
        case unavailable
        case transient
        case unknown
    }

    case userCancelled
    case permission(Operation)
    case persistence(Operation)
    case decode(Operation)
    case invariant(Operation)
    case unavailable(Operation)
    case transient(Operation)
    case unknown(Operation)

    var category: Category {
        switch self {
        case .userCancelled: .userCancelled
        case .permission: .permission
        case .persistence: .persistence
        case .decode: .decode
        case .invariant: .invariant
        case .unavailable: .unavailable
        case .transient: .transient
        case .unknown: .unknown
        }
    }

    var operation: Operation? {
        switch self {
        case .userCancelled:
            nil
        case .permission(let operation),
             .persistence(let operation),
             .decode(let operation),
             .invariant(let operation),
             .unavailable(let operation),
             .transient(let operation),
             .unknown(let operation):
            operation
        }
    }

    /// `nil` はユーザーキャンセルだけ。UI はこの値がある場合に限り alert を表示する。
    var presentation: AppErrorPresentation? {
        switch self {
        case .userCancelled:
            return nil
        case .permission:
            return AppErrorPresentation(
                title: "アクセスできません",
                message: "対象へのアクセス権限を確認して、もう一度お試しください。"
            )
        case .persistence(let operation):
            return AppErrorPresentation(
                title: "保存できませんでした",
                message: operation == .deleteImage
                    ? "画像を削除できませんでした。ファイルの状態を確認して、もう一度お試しください。"
                    : "変更を保存できませんでした。保存先の状態を確認して、もう一度お試しください。"
            )
        case .decode:
            return AppErrorPresentation(
                title: "画像を表示できません",
                message: "画像が破損しているか、対応していない形式の可能性があります。"
            )
        case .invariant(let operation):
            if operation == .deleteTelemetryIdentifier {
                return AppErrorPresentation(
                    title: "仮名IDを確認できません",
                    message: "アプリを再起動してから、もう一度お試しください。"
                )
            }
            return AppErrorPresentation(
                title: "操作を完了できません",
                message: "表示状態を更新できませんでした。フォルダを再読み込みしてください。"
            )
        case .unavailable(let operation):
            return AppErrorPresentation(
                title: operation == .openPath ? "パスが見つかりません" : "対象が見つかりません",
                message: "対象が移動または削除された可能性があります。場所を確認してください。"
            )
        case .transient(let operation):
            if operation == .deleteTelemetryIdentifier {
                return AppErrorPresentation(
                    title: "仮名IDを削除できませんでした",
                    message: "通信状態を確認して、もう一度お試しください。"
                )
            }
            return AppErrorPresentation(
                title: "一時的に処理できません",
                message: "しばらく待ってから、もう一度お試しください。"
            )
        case .unknown(let operation):
            if operation == .deleteTelemetryIdentifier {
                return AppErrorPresentation(
                    title: "仮名IDを確認できません",
                    message: "アプリを再起動してから、もう一度お試しください。"
                )
            }
            return AppErrorPresentation(
                title: "操作を完了できません",
                message: "予期しない問題が発生しました。もう一度お試しください。"
            )
        }
    }

    static func classify(_ error: Error, operation: Operation) -> AppError {
        if let appError = error as? AppError {
            return appError
        }
        if error is CancellationError {
            return .userCancelled
        }

        let cocoaError = error as NSError
        if cocoaError.domain == NSCocoaErrorDomain, cocoaError.code == NSUserCancelledError {
            return .userCancelled
        }
        if Self.isPermissionError(cocoaError) {
            return .permission(operation)
        }

        if let imageError = error as? ImageLoaderError {
            switch imageError {
            case .cancelled:
                return .userCancelled
            case .fileNotFound:
                return .unavailable(operation)
            case .decodeFailed:
                return .decode(operation)
            }
        }

        if let folderError = error as? FolderScanError {
            switch folderError {
            case .folderNotFound:
                return .unavailable(operation)
            case .accessDenied:
                return .permission(operation)
            }
        }

        if let fileError = error as? FileSystemError {
            switch fileError {
            case .fileNotFound:
                return .unavailable(operation)
            case .accessDenied:
                return .permission(operation)
            case .deleteFailed(_, let underlying), .attributeReadFailed(_, let underlying):
                return Self.isPermissionError(underlying as NSError)
                    ? .permission(operation)
                    : .persistence(operation)
            }
        }

        if let metadataError = error as? MetadataError {
            switch metadataError {
            case .fileNotFound:
                return .unavailable(operation)
            case .readFailed:
                return .permission(operation)
            case .invalidImage:
                return .decode(operation)
            }
        }

        if cocoaError.domain == NSURLErrorDomain {
            if cocoaError.code == NSURLErrorCancelled {
                return .userCancelled
            }
            return .transient(operation)
        }
        if cocoaError.domain == NSCocoaErrorDomain {
            return .persistence(operation)
        }
        switch operation {
        case .saveFavorite, .deleteImage, .cacheWrite:
            return .persistence(operation)
        case .deleteTelemetryIdentifier:
            return .transient(operation)
        default:
            return .unknown(operation)
        }
    }

    private static func isPermissionError(_ error: NSError) -> Bool {
        guard error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain else {
            return false
        }
        if error.domain == NSCocoaErrorDomain {
            return [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(error.code)
        }
        return [Int(EACCES), Int(EPERM)].contains(error.code)
    }
}

struct AppErrorPresentation: Equatable, Sendable {
    let title: String
    let message: String
}

extension Logger {
    /// 固定 category / operation だけを public にし、元 error は常に private にする。
    func log(_ appError: AppError, underlying error: Error? = nil) {
        let category = appError.category.rawValue
        let operation = appError.operation?.rawValue ?? "none"
        if let error {
            self.error(
                "Operation failed: category=\(category, privacy: .public) operation=\(operation, privacy: .public) detail=\(error.localizedDescription, privacy: .private)"
            )
        } else {
            self.error(
                "Operation failed: category=\(category, privacy: .public) operation=\(operation, privacy: .public)"
            )
        }
    }
}
