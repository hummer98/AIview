import Foundation

/// ディスクキャッシュの LRU インデックス（単一 plist 永続化）
///
/// - `version` 不一致 / 破損の場合はマイグレーションコードを書かず、
///   呼び出し側でフルスキャン再構築する運用で統一する。サムネイルは
///   再生成可能なのでデータロスではない。
/// - 永続化フォーマットは PropertyList。`save(to:)` は atomic write を使う。
struct DiskCacheIndex: Codable, Equatable {

    /// 現行バージョン
    static let currentVersion: Int = 1

    var version: Int
    var totalBytes: Int64
    var entries: [Entry]

    struct Entry: Codable, Equatable {
        var key: String
        var sizeBytes: Int64
        var accessedAt: Date
        var createdAt: Date
    }

    init(version: Int = Self.currentVersion, totalBytes: Int64 = 0, entries: [Entry] = []) {
        self.version = version
        self.totalBytes = totalBytes
        self.entries = entries
    }

    /// ファイルからロード。破損 / 未知バージョンの場合は nil を返す
    /// （呼び出し側でフルスキャン再構築すべき）。
    static func load(from url: URL) -> DiskCacheIndex? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = PropertyListDecoder()
        guard let index = try? decoder.decode(DiskCacheIndex.self, from: data) else {
            return nil
        }
        guard index.version == Self.currentVersion else { return nil }
        return index
    }

    /// ファイルへ保存。atomic write で中断時のゼロバイト化を回避。
    func save(to url: URL) throws {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
    }
}
