import XCTest
@testable import AIview

/// Baseline measurement only.
///
/// このテストは ImageLoader の Swift Concurrency 経路 (`Task(priority:)` ベース) の
/// レイテンシを計測する smoke test。`ThumbnailGenerator.ThumbnailPriority.high.qos` を
/// `.userInitiated` → `.utility` に格下げした効果は OperationQueue 経路で発現するため、
/// このテストでは exercise されない。Code A の効果検証は実機での矢印キー連打体感確認に委ねる。
final class ImageLoaderContentionTests: XCTestCase {
    private var tempFolder: URL!

    override func setUpWithError() throws {
        tempFolder = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageLoaderContentionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempFolder)
    }

    func testDisplayLoadLatency_underThumbnailContention_baseline() async throws {
        // 4MP 相当 (2048x2048) を 50 枚生成
        let images = try DummyImageGenerator.generateImages(count: 50, in: tempFolder)

        // cache 実質無効化 (currentSizeBytes > 0 で即 evict されるため毎回 decode が走る)
        let loader = ImageLoader(cacheManager: CacheManager(maxSizeBytes: 0))

        // .thumbnail priority で 50 枚並列投入 → queue を埋める
        for url in images {
            Task.detached(priority: .utility) {
                _ = try? await loader.loadImage(from: url, priority: .thumbnail, targetSize: nil)
            }
        }
        // queue が埋まるのを待つ
        try await Task.sleep(nanoseconds: 50_000_000)

        let target = images.first!
        let start = CFAbsoluteTimeGetCurrent()
        _ = try await loader.loadImage(from: target, priority: .display, targetSize: nil)
        let elapsedMs = (CFAbsoluteTimeGetCurrent() - start) * 1000

        // XCTContext は値を XCTest レポートへ残すため、CI ログから後追いできる
        await MainActor.run {
            XCTContext.runActivity(named: "display latency = \(String(format: "%.1f", elapsedMs))ms") { _ in }
        }

        // 性能の合否ではなく「display load が詰まらず完了する」ことだけを見る上限。
        // TSan 有効の GitHub runner では 50 枚の同時 decode と競合して 9〜11 秒かかる実測があり、
        // 5 秒では runner の速さで落ちていた。値の推移は上の activity で追う。
        XCTAssertLessThan(elapsedMs, 30_000, "計測経路が壊れていない（詰まらず完了する）")
    }
}
