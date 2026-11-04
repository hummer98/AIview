import Foundation
import Observation
import os
import XCTest
@testable import AIview

@MainActor
final class ImageBrowserFacadeTests: XCTestCase {
    func testInjectedControllerRemainsSingleSourceOfTruth() {
        let controller = BrowserSessionController(beepPlayer: NoopBeepPlayer())
        let sut = ImageBrowserViewModel(sessionController: controller)

        XCTAssertTrue(sut.sessionController === controller)
        XCTAssertFalse(sut.isPrivacyMode)

        sut.togglePrivacyMode()

        XCTAssertTrue(controller.isPrivacyMode)
        XCTAssertTrue(sut.isPrivacyMode)
    }

    func testNestedControllerMutationInvalidatesFacadeObservation() {
        let controller = BrowserSessionController(beepPlayer: NoopBeepPlayer())
        let sut = ImageBrowserViewModel(sessionController: controller)
        let invalidated = OSAllocatedUnfairLock(initialState: false)

        withObservationTracking {
            _ = sut.isPrivacyMode
        } onChange: {
            invalidated.withLock { $0 = true }
        }

        controller.togglePrivacyMode()

        XCTAssertTrue(invalidated.withLock { $0 })
        XCTAssertTrue(sut.isPrivacyMode)
    }

    func testCompatibilityInitializerBuildsUsableFacade() {
        let suiteName = "ImageBrowserFacadeTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let sut = ImageBrowserViewModel(
            beepPlayer: NoopBeepPlayer(),
            settingsStore: SettingsStore(defaults: defaults)
        )

        XCTAssertFalse(sut.hasImages)
        XCTAssertEqual(sut.slideshowInterval, SettingsStore.defaultSlideshowIntervalSeconds)
        XCTAssertTrue(sut._debugFolderScanSnapshot().isIdle)
    }
}
