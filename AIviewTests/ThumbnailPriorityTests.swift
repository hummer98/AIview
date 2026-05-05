import XCTest
@testable import AIview

final class ThumbnailPriorityTests: XCTestCase {
    func testHighPriority_qos_isUtility_toAvoidContentionWithDisplayLoad() {
        XCTAssertEqual(
            ThumbnailPriority.high.qos,
            .utility,
            ".high の qos はメイン画像 (.userInitiated) より一段低くしてコア競合を避ける設計"
        )
    }

    func testHighPriority_queuePriority_isHigh() {
        XCTAssertEqual(ThumbnailPriority.high.queuePriority, .high)
    }
}
