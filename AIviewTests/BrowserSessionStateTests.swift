import AppKit
import XCTest
@testable import AIview

final class BrowserSessionStateTests: XCTestCase {
    private let image = NSImage(size: NSSize(width: 2, height: 2))

    func testInitialScanIsLoadingUntilFirstSelectionCommits() throws {
        let url = URL(fileURLWithPath: "/tmp/browser-state-loading/first.png")
        var state = BrowserSessionState()

        state.beginScan(clearSelection: true)
        XCTAssertEqual(state.phase, .scanning)
        XCTAssertNil(state.selection)
        XCTAssertTrue(state.isLoading)

        state.updateScanProgress([url])
        XCTAssertTrue(state.isLoading, "pending発行前の初回scanもloadingを維持する")

        let pending = try XCTUnwrap(state.beginLoad(at: 0, completionPhase: .scanning))
        XCTAssertTrue(state.isLoading)
        XCTAssertTrue(state.commit(image: image, for: pending))

        XCTAssertEqual(state.phase, .scanning)
        XCTAssertEqual(state.selection?.url, url)
        XCTAssertFalse(state.isLoading, "初回selection commit後はscan継続中でも画像を表示できる")
        XCTAssertTrue(state.invariantsHold())
    }

    func testScanCompleteSortsEnumerationAndReanchorsCommittedSelection() throws {
        let folder = URL(fileURLWithPath: "/tmp/browser-state-order")
        let a = folder.appendingPathComponent("a.png")
        let b = folder.appendingPathComponent("b.png")
        let c = folder.appendingPathComponent("c.png")
        var state = BrowserSessionState()

        state.beginScan(clearSelection: true)
        state.updateScanProgress([b])
        let initialLoad = try XCTUnwrap(state.beginLoad(at: 0, completionPhase: .scanning))
        XCTAssertTrue(state.commit(image: image, for: initialLoad))

        let transition = state.transitionURLs(
            [c, b, a],
            anchorURL: b,
            fallbackIndex: 0,
            transitionPhase: .scanning
        )

        XCTAssertEqual(transition, .preserved(index: 1))
        XCTAssertEqual(state.sortedURLs, [a, b, c])
        XCTAssertEqual(state.selection?.url, b)
        XCTAssertEqual(state.selection?.index, 1)
        XCTAssertEqual(state.phase, .ready)
        XCTAssertTrue(state.invariantsHold())
    }

    func testSubdirectoryInsertionBeforeAnchorKeepsDisplayedURL() throws {
        let folder = URL(fileURLWithPath: "/tmp/browser-state-subdirectory")
        let parent = folder.appendingPathComponent("m.png")
        let subdirectoryFirst = folder.appendingPathComponent("sub/a.png")
        var state = BrowserSessionState()

        state.beginScan(clearSelection: true)
        state.updateScanProgress([parent])
        let load = try XCTUnwrap(state.beginLoad(at: 0, completionPhase: .scanning))
        XCTAssertTrue(state.commit(image: image, for: load))

        let transition = state.transitionURLs(
            [parent, subdirectoryFirst],
            anchorURL: parent,
            fallbackIndex: 0,
            transitionPhase: .scanning
        )

        XCTAssertEqual(transition, .preserved(index: 1))
        XCTAssertEqual(state.selection?.url, parent)
        let selectedIndex = try XCTUnwrap(state.selection?.index)
        XCTAssertEqual(state.sortedURLs[selectedIndex], parent)
        XCTAssertTrue(state.invariantsHold())
    }

    func testReloadUsesNearestIndexWhenAnchorWasRemoved() throws {
        let folder = URL(fileURLWithPath: "/tmp/browser-state-reload")
        let a = folder.appendingPathComponent("a.png")
        let b = folder.appendingPathComponent("b.png")
        let c = folder.appendingPathComponent("c.png")
        var state = BrowserSessionState()

        state.beginScan(clearSelection: true)
        state.updateScanProgress([a, b, c])
        let displayed = try XCTUnwrap(state.beginLoad(at: 1, completionPhase: .scanning))
        XCTAssertTrue(state.commit(image: image, for: displayed))

        let transition = state.transitionURLs(
            [a, c],
            anchorURL: b,
            fallbackIndex: 1,
            transitionPhase: .scanning
        )
        XCTAssertEqual(transition, .load(index: 1))
        XCTAssertNil(state.selection)

        let replacement = try XCTUnwrap(state.beginLoad(at: 1))
        XCTAssertTrue(state.commit(image: image, for: replacement))
        XCTAssertEqual(state.selection?.url, c)
        XCTAssertEqual(state.selection?.index, 1)
        XCTAssertTrue(state.invariantsHold())
    }

    func testEmptyCompletionIsTerminalAndNotLoading() throws {
        var state = BrowserSessionState()
        state.beginScan(clearSelection: true)

        XCTAssertEqual(
            state.transitionURLs([], anchorURL: nil, fallbackIndex: 0, transitionPhase: .scanning),
            .empty
        )
        XCTAssertEqual(state.phase, .empty)
        XCTAssertTrue(state.sortedURLs.isEmpty)
        XCTAssertNil(state.selection)
        XCTAssertNil(state.pendingLoad)
        XCTAssertFalse(state.isLoading)
        XCTAssertTrue(state.invariantsHold())
    }

    func testDeletingSelectionIsIdentityMatchedButNotActionable() throws {
        let url = URL(fileURLWithPath: "/tmp/browser-state-action/a.png")
        var state = BrowserSessionState()
        state.beginScan(clearSelection: true)
        state.updateScanProgress([url])
        let load = try XCTUnwrap(state.beginLoad(at: 0))
        XCTAssertTrue(state.commit(image: image, for: load))
        let captured = try XCTUnwrap(state.validatedSelectionForSideEffect())

        XCTAssertTrue(state.beginDeletion(captured))

        XCTAssertEqual(state.phase, .deleting)
        XCTAssertNil(state.validatedSelectionForSideEffect())
        XCTAssertFalse(state.isCurrentActionable(captured))
        XCTAssertTrue(state.matchesCommittedIdentity(captured))
        XCTAssertTrue(state.invariantsHold())
    }
}
