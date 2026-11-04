import XCTest
@testable import AIview

/// 拡大時の二本指スクロール / ホイールによるパン量変換
final class ScrollWheelPanTests: XCTestCase {
    func testPreciseTrackpadDeltaIsUsedAsIs() {
        let delta = ScrollWheelPan.panDelta(deltaX: 3.5, deltaY: -12, hasPreciseDeltas: true)
        XCTAssertEqual(delta, CGSize(width: 3.5, height: -12))
    }

    func testLineBasedWheelDeltaIsScaledToPoints() {
        let delta = ScrollWheelPan.panDelta(deltaX: 0, deltaY: 1, hasPreciseDeltas: false)
        XCTAssertEqual(delta, CGSize(width: 0, height: ScrollWheelPan.lineDeltaMultiplier))
    }
}

/// カーソル位置を中心にした拡縮のパン補正
final class ZoomAnchorTests: XCTestCase {
    private let container = CGSize(width: 800, height: 600)

    func testZoomAtCenterKeepsPan() {
        let pan = ZoomAnchor.pan(.zero, from: 1, to: 2, anchor: CGPoint(x: 400, y: 300), container: container)
        XCTAssertEqual(pan, .zero)
    }

    func testZoomInKeepsPointUnderCursorFixed() {
        // anchor は中央から (+200, -100)。2倍にするとその点を戻すため反対方向へずらす
        let pan = ZoomAnchor.pan(.zero, from: 1, to: 2, anchor: CGPoint(x: 600, y: 200), container: container)
        XCTAssertEqual(pan, CGSize(width: -200, height: 100))
    }

    func testAnchoredPointStaysFixedWithExistingPan() {
        let start = CGSize(width: 50, height: -30)
        let anchor = CGPoint(x: 100, y: 450)
        let ax = anchor.x - container.width / 2
        let ay = anchor.y - container.height / 2
        // 画像上の点 u = (a - pan) / scale が拡縮前後で同じ画面位置に来ること
        let u = CGPoint(x: (ax - start.width) / 1.5, y: (ay - start.height) / 1.5)
        let pan = ZoomAnchor.pan(start, from: 1.5, to: 3, anchor: anchor, container: container)
        XCTAssertEqual(u.x * 3 + pan.width, ax, accuracy: 1e-9)
        XCTAssertEqual(u.y * 3 + pan.height, ay, accuracy: 1e-9)
    }
}
