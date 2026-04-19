import Foundation
import CryptoKit

/// ディスクキャッシュのキー素材生成
///
/// - `fileIdentifierKey` (ボリューム内 inode UInt64) + `volumeIdentifierKey` を優先素材とし、
///   取得失敗時は `resolvingSymlinksInPath()` 後のパスにフォールバックする。
/// - macOS 13.3+ で利用可能 (`MACOSX_DEPLOYMENT_TARGET=14.0` 前提)。
/// - シンボリックリンクはリンク解決後の実体に対して identifier を取得するため、
///   リンク元とリンク先は同一キャッシュを共有する。
enum DiskCacheIdentity {

    /// キー種別
    enum Kind: String {
        case ino
        case path
    }

    /// 生成されたキー
    struct Key: Equatable, Sendable {
        let kind: Kind
        let hashHex: String

        /// デバッグ用の短文字列（ファイル名プレフィクスではない）
        var debugDescription: String { "\(kind.rawValue)_\(hashHex)" }
    }

    /// URL からキーを生成する。必ず成功する（最終的にパスフォールバック）。
    static func key(for url: URL) -> Key {
        let resolved = url.resolvingSymlinksInPath()

        if let inoKey = makeInoKey(for: resolved) {
            return inoKey
        }
        return makePathKey(for: resolved)
    }

    // MARK: - Private

    private static func makeInoKey(for url: URL) -> Key? {
        let values: URLResourceValues
        do {
            values = try url.resourceValues(forKeys: [.fileIdentifierKey, .volumeIdentifierKey])
        } catch {
            return nil
        }

        guard let rawIdentifier = values.allValues[.fileIdentifierKey],
              let rawVolume = values.allValues[.volumeIdentifierKey] else {
            return nil
        }

        guard let inoString = inodeString(from: rawIdentifier) else {
            return nil
        }
        let volumeString = volumeIdentifierString(from: rawVolume)

        let material = "\(volumeString):\(inoString)"
        return Key(kind: .ino, hashHex: sha256HexPrefix(material, bytes: 16))
    }

    private static func makePathKey(for url: URL) -> Key {
        let path = url.path
        return Key(kind: .path, hashHex: sha256HexPrefix(path, bytes: 16))
    }

    /// `fileIdentifierKey` の返り値は macOS 13.3+ で UInt64 相当。
    /// Objective-C 経由で NSNumber としても来るため両方受ける。
    private static func inodeString(from raw: Any) -> String? {
        if let n = raw as? UInt64 { return String(n) }
        if let n = raw as? Int { return String(n) }
        if let n = raw as? Int64 { return String(n) }
        if let n = raw as? NSNumber { return n.stringValue }
        return nil
    }

    private static func volumeIdentifierString(from raw: Any) -> String {
        if let uuid = raw as? UUID { return uuid.uuidString }
        if let nsuuid = raw as? NSUUID { return nsuuid.uuidString }
        return String(describing: raw)
    }

    private static func sha256HexPrefix(_ string: String, bytes: Int) -> String {
        let data = Data(string.utf8)
        let hash = SHA256.hash(data: data)
        return hash.prefix(bytes).map { String(format: "%02x", $0) }.joined()
    }
}
