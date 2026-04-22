import Foundation
import os

/// Per-folder サムネイルディスクキャッシュ
///
/// 設計原則 (`CLAUDE.md` > 設計思想 > サムネイルキャッシュの保存先):
/// - キャッシュは各フォルダ直下の `.aiview/` サブフォルダに保存
/// - ファイル名は元ファイル名 + `.jpg` (例: `sunset.heic` → `.aiview/sunset.heic.jpg`)
/// - mtime 等値比較で hit/miss 判定 (書き込み時に `setAttributes` で pre-stamp)
/// - サイズは 80×80 固定 (thumbnailSize パラメータなし)
/// - hash / identity key / シャーディング / 全体 LRU / index plist は持たない
///
/// Safety Notes:
/// - `.aiview/` は hidden なので `FolderScanner` の `skipsHiddenFiles` で
///   自動スキップされる。画像リストに `.aiview/*.jpg` が混じることはない。
/// - `.aiview/favorites.json` は `FavoritesStore` が共有利用するため、
///   ディレクトリ単位の削除は行わない (ファイル単位のみ)。
/// - mtime-preserving copy (`cp -p`, `rsync -a`, Photos export) で内容が変わった場合は
///   stale を返す。これは設計上の既知・意図的な挙動 (content hash を持たないため)。
/// - 画像ファイルだけ削除された場合、`.aiview/<name>.jpg` は孤児として残り続ける。
///   全体 LRU を廃した以上これは受容する (フォルダごと削除された時のみ消える)。
actor DiskCacheStore {

    private let fileManager = FileManager.default

    // MARK: - Metrics

    private var readCount: UInt64 = 0
    private var writeCount: UInt64 = 0
    private var readHistogram = LatencyHistogram()
    private var writeHistogram = LatencyHistogram()

    init() {}

    // MARK: - Public API

    /// サムネイルをディスクから取得する。
    /// - 判定: キャッシュファイルの mtime が元ファイルの `modificationDate` と完全一致するときのみ hit。
    ///   不一致なら stale とみなしキャッシュファイルを削除して nil を返す (best effort)。
    func getThumbnail(originalURL: URL, modificationDate: Date) async -> Data? {
        let cacheURL = cacheFileURL(for: originalURL)
        guard fileManager.fileExists(atPath: cacheURL.path) else { return nil }

        let cacheMtime: Date?
        do {
            cacheMtime = try cacheURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        } catch {
            Logger.cacheManager.warning(
                "Failed to read cache mtime: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }

        guard let cacheMtime, cacheMtime == modificationDate else {
            try? fileManager.removeItem(at: cacheURL)
            return nil
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let data = try Data(contentsOf: cacheURL)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            readHistogram.record(elapsedMs)
            readCount &+= 1
            Logger.cacheManager.debug("Disk cache hit: \(cacheURL.lastPathComponent, privacy: .public)")
            return data
        } catch {
            Logger.cacheManager.warning(
                "Failed to read disk cache: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    /// サムネイルをディスクに保存する。
    /// - 保存先: `originalURL` と同じフォルダの `.aiview/<lastPathComponent>.jpg`
    /// - 書き込み後に `setAttributes` で mtime を `modificationDate` にそろえる。
    ///   失敗時は書いたばかりの cache file を削除して throw (loop 回避)。
    /// - 書き込み不可フォルダ等の失敗は throw。フォールバックは行わない。
    func storeThumbnail(_ data: Data, originalURL: URL, modificationDate: Date) async throws {
        let cacheURL = cacheFileURL(for: originalURL)
        let aiviewDir = cacheURL.deletingLastPathComponent()

        do {
            try fileManager.createDirectory(at: aiviewDir, withIntermediateDirectories: true)
        } catch {
            Logger.cacheManager.error(
                "Failed to create .aiview directory: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Logger.cacheManager.error(
                "Failed to store thumbnail: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        writeHistogram.record(elapsedMs)
        writeCount &+= 1

        // `setResourceValues(.contentModificationDate)` は APFS 上で ns 精度を保持する。
        // `FileManager.setAttributes(.modificationDate:)` は秒精度に丸めてしまうため使わない
        // (そうすると `resourceValues(.contentModificationDateKey)` で読み戻した値と
        // 元の modificationDate の等値比較が常に失敗する)。
        do {
            var urlCopy = cacheURL
            var values = URLResourceValues()
            values.contentModificationDate = modificationDate
            try urlCopy.setResourceValues(values)
        } catch {
            Logger.cacheManager.warning(
                "Failed to stamp cache mtime; removing partial cache: \(error.localizedDescription, privacy: .public)"
            )
            try? fileManager.removeItem(at: cacheURL)
            throw error
        }

        Logger.cacheManager.debug("Stored thumbnail: \(cacheURL.lastPathComponent, privacy: .public)")
    }

    // MARK: - Metrics

    func metricsSnapshot() -> DiskIOMetricsSnapshot {
        DiskIOMetricsSnapshot(
            readCount: readCount,
            writeCount: writeCount,
            readHistogram: readHistogram.snapshot(),
            writeHistogram: writeHistogram.snapshot(),
            evictCount: 0
        )
    }

    // MARK: - Private

    private func cacheFileURL(for originalURL: URL) -> URL {
        let folder = originalURL.deletingLastPathComponent()
        let fileName = originalURL.lastPathComponent + ".jpg"
        return folder
            .appendingPathComponent(".aiview", isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
