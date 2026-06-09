import Foundation
import os

/// ナビゲーション診断ロガー。
///
/// 追跡対象の事象:
/// 「左右カーソルで index（サムネイル位置）は進むのに、メイン画像が切り替わらないことがある」。
/// 現在は表示同期方式（`jumpToIndex` が `targetIndex` だけ進め、`loadAndCommit` の完了で
/// `currentIndex` を確定する）でこの状態自体を防いでいるが、ロードが想定外にサイレント脱落
/// （生存タスクなのに確定に至らない／キャンセルされていないのに `.cancelled` が返る等）した
/// 場合に備え、確定の有無を計装してインシデントを残す。
///
/// 設計:
/// - 通常のナビ/ロードイベントは **メモリ上のリングバッファ (breadcrumb) に積むだけ**。
///   ファイル I/O はしないので、キー連打（オートリピート）でも負荷はかからない。
/// - **異常を検出したときだけ**、リングバッファの直近履歴をまとめてログファイルへ追記する。
///   これにより「発生した瞬間の前後の流れ」がファイル単体で追跡できる。
/// - ファイルは `~/Library/Logs/AIview/navigation-incidents.log`（Console.app の
///   「ログレポート」や Finder からも参照可能）。2MB でローテートする。
///
/// 本ロガーは並行性層ではなく診断専用。状態を持たず、異常時のみ書き込む軽量実装に留める。
final class NavigationDiagnostics: @unchecked Sendable {
    static let shared = NavigationDiagnostics()

    private let lock = NSLock()
    private var ring: [String] = []
    private let ringCapacity = 256

    /// ファイル書き込み専用の直列キュー。MainActor をブロックしないため非同期で書く。
    private let ioQueue = DispatchQueue(label: "com.ridgeroot.AIview.NavigationDiagnostics")
    private let maxFileBytes = 2 * 1024 * 1024

    /// インシデントログの出力先。`~/Library/Logs/AIview/navigation-incidents.log`
    let fileURL: URL?

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private init() {
        let fm = FileManager.default
        if let library = try? fm.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            let logsDir = library.appendingPathComponent("Logs/AIview", isDirectory: true)
            try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
            self.fileURL = logsDir.appendingPathComponent("navigation-incidents.log")
        } else {
            self.fileURL = nil
        }
    }

    private static func timestamp() -> String {
        formatter.string(from: Date())
    }

    /// 通常イベント。メモリのリングバッファに積むだけで、ファイルには書かない。
    func breadcrumb(_ message: String) {
        let line = "\(Self.timestamp())  \(message)"
        lock.withLock {
            ring.append(line)
            if ring.count > ringCapacity {
                ring.removeFirst(ring.count - ringCapacity)
            }
        }
    }

    /// 異常検出。リングバッファをファイルへ flush し、os.Logger.fault にも残す。
    /// - Parameter message: 異常の要約（インシデントの見出しになる）。
    func reportAnomaly(_ message: String) {
        let line = "\(Self.timestamp())  ‼️ ANOMALY: \(message)"
        let snapshot: [String] = lock.withLock {
            ring.append(line)
            if ring.count > ringCapacity {
                ring.removeFirst(ring.count - ringCapacity)
            }
            return ring
        }
        Logger.app.fault("Navigation anomaly: \(message, privacy: .public)")
        flush(header: message, breadcrumbs: snapshot)
    }

    private func flush(header: String, breadcrumbs: [String]) {
        guard let fileURL else { return }
        let maxBytes = maxFileBytes
        ioQueue.async {
            var text = "\n===== INCIDENT \(Self.timestamp()) — \(header) =====\n"
            text += breadcrumbs.joined(separator: "\n")
            text += "\n===== END INCIDENT =====\n"
            Self.append(text, to: fileURL, maxBytes: maxBytes)
        }
    }

    /// ファイル末尾へ追記。サイズ超過時は 1 世代だけローテートする（`.1` へ退避して切り詰め）。
    private static func append(_ text: String, to fileURL: URL, maxBytes: Int) {
        let fm = FileManager.default
        guard let data = text.data(using: .utf8) else { return }

        // ローテート判定
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > maxBytes {
            let rotated = fileURL.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: fileURL, to: rotated)
        }

        if fm.fileExists(atPath: fileURL.path),
           let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
