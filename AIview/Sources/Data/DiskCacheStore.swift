import Foundation
import CryptoKit
import os

/// ディスクキャッシュストア
///
/// - キー: `DiskCacheIdentity` (fileIdentifierKey + volumeIdentifierKey、
///   取得失敗時は resolvingSymlinksInPath 後のパスにフォールバック) + mtime + size。
/// - 保存先: 既定 `~/Library/Application Support/AIview/DiskCache/`。
///   テスト用途では `baseURL` を注入可能。
/// - LRU: `DiskCacheIndex` で単一 plist 永続化。0.95 閾値で evict、0.80 まで削る。
/// - ライフサイクル: `flush()` を AIviewApp から ScenePhase/willTerminate で発火。
actor DiskCacheStore {

    // MARK: - Configuration (immutable)

    private let maxBytes: Int64
    private let storeRoot: URL
    private let thumbnailsDir: URL
    private let indexURL: URL
    private let fileManager = FileManager.default
    private let isInjectedBase: Bool

    // MARK: - Constants

    private static let highWatermarkRatio: Double = 0.95
    private static let lowWatermarkRatio: Double = 0.80
    private static let maxEvictionsPerPass: Int = 200
    private static let debounceNanoseconds: UInt64 = 1_000_000_000
    private static let shardBucketHexLength: Int = 2

    // MARK: - Index State

    private var entriesByKey: [String: DiskCacheIndex.Entry] = [:]
    private var totalBytes: Int64 = 0
    private var indexLoaded: Bool = false
    private var isDisabled: Bool = false
    private var deferredOps: [DeferredOp] = []
    private var loadTask: Task<Void, Never>?
    private var debounceTask: Task<Void, Never>?

    // MARK: - Metrics

    private var readCount: UInt64 = 0
    private var writeCount: UInt64 = 0
    private var evictCount: UInt64 = 0
    private var flushCount: UInt64 = 0
    private var readHistogram = LatencyHistogram()
    private var writeHistogram = LatencyHistogram()

    // MARK: - Initialization

    init(maxSizeBytes: Int = 512 * 1024 * 1024, baseURL: URL? = nil, autoLoad: Bool = true) {
        self.maxBytes = Int64(maxSizeBytes)
        self.isInjectedBase = (baseURL != nil)

        let root: URL
        if let baseURL {
            root = baseURL
        } else {
            root = Self.defaultStoreRoot()
        }
        self.storeRoot = root
        self.thumbnailsDir = root.appendingPathComponent("thumbnails", isDirectory: true)
        self.indexURL = root.appendingPathComponent("index.plist")

        if autoLoad {
            self.loadTask = Task { [weak self] in
                guard let self else { return }
                await self.performInitialSetup()
            }
        }
    }

    // Back-compat convenience for tests that used old `DiskCacheStore(baseURL:)` positional form.
    // The main init above already supports `baseURL:` labeled access.

    private static func defaultStoreRoot() -> URL {
        let fm = FileManager.default
        if let url = try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ) {
            return url.appendingPathComponent("AIview/DiskCache", isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/AIview/DiskCache", isDirectory: true)
    }

    // MARK: - Public API

    /// サムネイルをディスクから取得
    func getThumbnail(
        originalURL: URL,
        thumbnailSize: CGSize,
        modificationDate: Date
    ) async -> Data? {
        if isDisabled { return nil }

        let key = thumbnailCacheFileName(
            for: originalURL,
            size: thumbnailSize,
            modificationDate: modificationDate
        )
        let fileURL = cacheFileURL(for: key)

        guard fileManager.fileExists(atPath: fileURL.path) else {
            if indexLoaded, let existing = entriesByKey[key] {
                totalBytes -= existing.sizeBytes
                entriesByKey.removeValue(forKey: key)
                scheduleFlush()
            }
            return nil
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            let data = try Data(contentsOf: fileURL)
            let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            readHistogram.record(elapsedMs)
            readCount &+= 1

            let now = Date()
            if indexLoaded {
                touchEntry(key: key, fallbackFileURL: fileURL, fallbackSize: Int64(data.count), at: now)
                scheduleFlush()
            } else {
                deferredOps.append(.touch(key: key, accessedAt: now))
            }

            Logger.cacheManager.debug("Disk cache hit: \(fileURL.lastPathComponent, privacy: .public)")
            return data
        } catch {
            Logger.cacheManager.warning("Failed to read disk cache: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// サムネイルをディスクに保存
    func storeThumbnail(
        _ data: Data,
        originalURL: URL,
        thumbnailSize: CGSize,
        modificationDate: Date
    ) async throws {
        if isDisabled { return }

        let key = thumbnailCacheFileName(
            for: originalURL,
            size: thumbnailSize,
            modificationDate: modificationDate
        )
        let fileURL = cacheFileURL(for: key)
        let shardDir = fileURL.deletingLastPathComponent()

        if !fileManager.fileExists(atPath: shardDir.path) {
            do {
                try fileManager.createDirectory(at: shardDir, withIntermediateDirectories: true)
            } catch {
                Logger.cacheManager.error(
                    "Failed to create cache shard directory: \(error.localizedDescription, privacy: .public)"
                )
                throw error
            }
        }

        let t0 = CFAbsoluteTimeGetCurrent()
        do {
            try data.write(to: fileURL, options: .atomic)
        } catch {
            Logger.cacheManager.error(
                "Failed to store thumbnail: \(error.localizedDescription, privacy: .public)"
            )
            throw error
        }
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        writeHistogram.record(elapsedMs)
        writeCount &+= 1

        let size = Int64(data.count)
        let now = Date()
        let entry = DiskCacheIndex.Entry(
            key: key,
            sizeBytes: size,
            accessedAt: now,
            createdAt: now
        )

        if indexLoaded {
            if let existing = entriesByKey[key] {
                totalBytes -= existing.sizeBytes
            }
            entriesByKey[key] = entry
            totalBytes += size
            evictIfNeeded()
            scheduleFlush()
        } else {
            deferredOps.append(.add(entry))
        }

        Logger.cacheManager.debug("Stored thumbnail: \(fileURL.lastPathComponent, privacy: .public)")
    }

    /// キャッシュ全削除 (`clearCache(for:)` の後継, M1)
    func clearAll() async {
        debounceTask?.cancel()
        debounceTask = nil

        if fileManager.fileExists(atPath: thumbnailsDir.path) {
            try? fileManager.removeItem(at: thumbnailsDir)
        }
        try? fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: indexURL.path) {
            try? fileManager.removeItem(at: indexURL)
        }

        entriesByKey.removeAll()
        totalBytes = 0
        deferredOps.removeAll()
        indexLoaded = true
        Logger.cacheManager.info("Cleared all disk cache entries")
    }

    /// 最近開いたフォルダの `.aiview/` を削除 (起動時一括マイグレーション)
    func migrateLegacyCaches(folders: [URL]) async {
        if isInjectedBase { return }
        for folder in folders {
            await cleanupLegacyCacheIfPresent(at: folder)
        }
    }

    /// 指定フォルダの `.aiview/` 配下の旧サムネイル (*.jpg) のみ削除 (フォルダオープン時の遅延クリーンアップ、m4)
    ///
    /// `FavoritesStore` が同じ `.aiview/` 配下に `favorites.json` を保存しているため、
    /// ディレクトリごと削除せず `*.jpg` (旧キャッシュ命名) のみを対象にする。
    /// サムネイルを全て削除した結果ディレクトリが空なら、ディレクトリも削除する。
    func cleanupLegacyCacheIfPresent(at folder: URL) async {
        if isInjectedBase { return }
        let legacyDir = folder.appendingPathComponent(".aiview")
        guard fileManager.fileExists(atPath: legacyDir.path) else { return }

        var removed = 0
        if let children = try? fileManager.contentsOfDirectory(
            at: legacyDir,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for child in children {
                let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if !isDir, child.pathExtension.lowercased() == "jpg" {
                    try? fileManager.removeItem(at: child)
                    removed += 1
                }
            }
        }

        if let remaining = try? fileManager.contentsOfDirectory(atPath: legacyDir.path),
           remaining.isEmpty {
            try? fileManager.removeItem(at: legacyDir)
        }

        if removed > 0 {
            Logger.cacheManager.info(
                "Cleaned up \(removed, privacy: .public) legacy thumbnails under .aiview of: \(folder.lastPathComponent, privacy: .public)"
            )
        }
    }

    // MARK: - Flush

    /// 即時保存。debounce task を cancel して実行し、ロード未完了なら完了を待つ。
    func flush() async {
        debounceTask?.cancel()
        debounceTask = nil
        await ensureLoaded()
        saveIndexNow()
        flushCount &+= 1
    }

    private func scheduleFlush() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.debounceNanoseconds)
            guard !Task.isCancelled else { return }
            await self?.saveIndexNow()
        }
    }

    private func saveIndexNow() {
        if isDisabled { return }
        if !indexLoaded { return }

        let index = DiskCacheIndex(
            version: DiskCacheIndex.currentVersion,
            totalBytes: totalBytes,
            entries: Array(entriesByKey.values)
        )
        do {
            try index.save(to: indexURL)
            Logger.cacheManager.debug(
                "Saved disk cache index: \(self.entriesByKey.count, privacy: .public) entries"
            )
        } catch {
            Logger.cacheManager.error(
                "Failed to save disk cache index: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    // MARK: - Metrics

    func metricsSnapshot() -> DiskIOMetricsSnapshot {
        DiskIOMetricsSnapshot(
            readCount: readCount,
            writeCount: writeCount,
            readHistogram: readHistogram.snapshot(),
            writeHistogram: writeHistogram.snapshot(),
            evictCount: evictCount
        )
    }

    func stateSnapshot() -> DiskCacheStateSnapshot {
        DiskCacheStateSnapshot(
            totalBytes: totalBytes,
            entryCount: entriesByKey.count,
            maxBytes: maxBytes
        )
    }

    // MARK: - Private State Operations

    private func touchEntry(key: String, fallbackFileURL: URL, fallbackSize: Int64, at time: Date) {
        if var entry = entriesByKey[key] {
            if time > entry.accessedAt {
                entry.accessedAt = time
            }
            entriesByKey[key] = entry
        } else {
            let size: Int64
            if let value = try? fallbackFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                size = Int64(value)
            } else {
                size = fallbackSize
            }
            let entry = DiskCacheIndex.Entry(
                key: key,
                sizeBytes: size,
                accessedAt: time,
                createdAt: time
            )
            entriesByKey[key] = entry
            totalBytes += size
        }
    }

    private func evictIfNeeded() {
        let highThreshold = Int64(Double(maxBytes) * Self.highWatermarkRatio)
        guard totalBytes > highThreshold else { return }

        let lowThreshold = Int64(Double(maxBytes) * Self.lowWatermarkRatio)
        var evicted = 0

        let sortedEntries = entriesByKey.values.sorted { $0.accessedAt < $1.accessedAt }
        for entry in sortedEntries {
            if evicted >= Self.maxEvictionsPerPass { break }
            if totalBytes <= lowThreshold { break }

            let fileURL = cacheFileURL(for: entry.key)
            try? fileManager.removeItem(at: fileURL)
            entriesByKey.removeValue(forKey: entry.key)
            totalBytes -= entry.sizeBytes
            evicted += 1
            evictCount &+= 1
        }

        if evicted > 0 {
            Logger.cacheManager.info(
                "Evicted \(evicted, privacy: .public) disk cache entries, total=\(self.totalBytes, privacy: .public)"
            )
        }
    }

    // MARK: - Loading

    private func ensureLoaded() async {
        if indexLoaded { return }
        if let loadTask {
            _ = await loadTask.value
            return
        }
        await performInitialSetup()
    }

    private func performInitialSetup() async {
        guard !indexLoaded else { return }

        do {
            try fileManager.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
        } catch {
            Logger.cacheManager.error(
                "Failed to create disk cache directory: \(error.localizedDescription, privacy: .public)"
            )
            isDisabled = true
            indexLoaded = true
            return
        }

        applyExcludedFromBackup()

        if let loaded = DiskCacheIndex.load(from: indexURL) {
            entriesByKey = Dictionary(uniqueKeysWithValues: loaded.entries.map { ($0.key, $0) })
            totalBytes = loaded.totalBytes
            Logger.cacheManager.info(
                "Loaded disk cache index: \(self.entriesByKey.count, privacy: .public) entries"
            )
        } else {
            rebuildIndexFromDisk()
        }

        applyDeferredOps()
        evictIfNeeded()
        indexLoaded = true
    }

    private func applyExcludedFromBackup() {
        var rootURL = storeRoot
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
    }

    private func rebuildIndexFromDisk() {
        entriesByKey.removeAll()
        totalBytes = 0

        guard let enumerator = fileManager.enumerator(
            at: thumbnailsDir,
            includingPropertiesForKeys: [
                .fileSizeKey,
                .contentAccessDateKey,
                .contentModificationDateKey,
                .creationDateKey,
                .isDirectoryKey
            ],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var rebuildCount = 0
        for case let fileURL as URL in enumerator {
            do {
                let values = try fileURL.resourceValues(forKeys: [
                    .fileSizeKey,
                    .contentAccessDateKey,
                    .contentModificationDateKey,
                    .creationDateKey,
                    .isDirectoryKey
                ])
                if values.isDirectory == true { continue }
                guard fileURL.pathExtension == "jpg" else { continue }
                guard let fileSize = values.fileSize else { continue }
                let size = Int64(fileSize)
                let accessedAt = values.contentAccessDate ?? values.contentModificationDate ?? Date()
                let createdAt = values.creationDate ?? values.contentModificationDate ?? Date()
                let key = fileURL.lastPathComponent
                let entry = DiskCacheIndex.Entry(
                    key: key,
                    sizeBytes: size,
                    accessedAt: accessedAt,
                    createdAt: createdAt
                )
                entriesByKey[key] = entry
                totalBytes += size
                rebuildCount += 1
            } catch {
                continue
            }
        }
        Logger.cacheManager.info(
            "Rebuilt disk cache index from scan: \(rebuildCount, privacy: .public) entries, totalBytes=\(self.totalBytes, privacy: .public)"
        )
    }

    private func applyDeferredOps() {
        for op in deferredOps {
            switch op {
            case .touch(let key, let at):
                if var entry = entriesByKey[key] {
                    if at > entry.accessedAt {
                        entry.accessedAt = at
                    }
                    entriesByKey[key] = entry
                }
            case .add(let entry):
                if let existing = entriesByKey[entry.key] {
                    totalBytes -= existing.sizeBytes
                }
                entriesByKey[entry.key] = entry
                totalBytes += entry.sizeBytes
            case .remove(let key):
                if let existing = entriesByKey[key] {
                    totalBytes -= existing.sizeBytes
                    entriesByKey.removeValue(forKey: key)
                }
            }
        }
        deferredOps.removeAll()
    }

    // MARK: - Path / Name

    func thumbnailCacheFileName(
        for originalURL: URL,
        size: CGSize,
        modificationDate: Date
    ) -> String {
        let identity = DiskCacheIdentity.key(for: originalURL)
        let modDateString = formattedModificationDate(modificationDate)
        let sizeString = "\(Int(size.width))x\(Int(size.height))"
        return "\(identity.kind.rawValue)_\(identity.hashHex)_\(modDateString)_\(sizeString).jpg"
    }

    func cacheFileURL(for fileName: String) -> URL {
        let shardPrefix = shardBucket(for: fileName)
        return thumbnailsDir
            .appendingPathComponent(shardPrefix, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// シャードバケット: 先頭 `<kind>_` の後ろ 2 文字 (256 バケット, m6)。
    private func shardBucket(for fileName: String) -> String {
        if let underscoreIdx = fileName.firstIndex(of: "_") {
            let afterUnderscore = fileName[fileName.index(after: underscoreIdx)...]
            let prefix = afterUnderscore.prefix(Self.shardBucketHexLength)
            if prefix.count == Self.shardBucketHexLength {
                return String(prefix)
            }
        }
        return String(repeating: "0", count: Self.shardBucketHexLength)
    }

    private func formattedModificationDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: date)
    }

    // MARK: - Test Hooks (actor-isolated, access via `await`)

    func testHookFlushCount() -> UInt64 { flushCount }
    func testHookEvictCount() -> UInt64 { evictCount }
    func testHookEntryCount() -> Int { entriesByKey.count }
    func testHookTotalBytes() -> Int64 { totalBytes }
    func testHookMaxBytes() -> Int64 { maxBytes }
    func testHookIndexLoaded() -> Bool { indexLoaded }
    func testHookIsDisabled() -> Bool { isDisabled }
    func testHookEntry(key: String) -> DiskCacheIndex.Entry? { entriesByKey[key] }
    func testHookAllKeys() -> [String] { Array(entriesByKey.keys) }
    func testHookStoreRoot() -> URL { storeRoot }
    func testHookThumbnailsDir() -> URL { thumbnailsDir }
    func testHookIndexURL() -> URL { indexURL }

    func testHookPerformInitialSetup() async {
        await performInitialSetup()
    }

    func testHookFlushDeferredOpsCount() -> Int { deferredOps.count }

    /// Backup 除外属性の確認用
    func testHookStoreRootIsExcludedFromBackup() -> Bool? {
        try? storeRoot.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
    }

    // MARK: - Deferred Ops

    private enum DeferredOp {
        case touch(key: String, accessedAt: Date)
        case add(DiskCacheIndex.Entry)
        case remove(key: String)
    }
}
