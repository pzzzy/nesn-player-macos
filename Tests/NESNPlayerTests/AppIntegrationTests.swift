import XCTest
import AppKit
@testable import NESNPlayer

@MainActor private final class CatalogTestWindow: NSWindow {
    override func makeKeyAndOrderFront(_ sender: Any?) {}
    override func close() {
        delegate?.windowWillClose?(Notification(name: NSWindow.willCloseNotification, object: self))
    }
}

final class AppIntegrationTests: XCTestCase {
    func testUltraHDUsesFeedNotProgramTitle() {
        let choice = WatchChoice(id: "fixture", title: "4K promo", kind: .liveEvent, isLive: true, streamTitle: "NESN HD")
        XCTAssertFalse(playbackIsUltraHD(choice))
        let uhd = WatchChoice(id: "fixture", title: "Game", kind: .liveEvent, isLive: true, streamTitle: "NESN 4K")
        XCTAssertTrue(playbackIsUltraHD(uhd))
    }

    @MainActor func testRouteTransitionsDrainBeforeShutdown() async {
        var events: [String] = []
        let routes = PlaybackAudioCoordinator(acquire: { events.append("acquire") }, release: { events.append("release") })
        routes.setLocalPlayback(true)
        await routes.wait()
        routes.setLocalPlayback(false)
        await routes.wait()
        routes.setLocalPlayback(true)
        await routes.wait()
        await routes.shutdown()
        XCTAssertEqual(events, ["acquire", "release", "acquire", "release"])
        routes.setLocalPlayback(true)
        await routes.wait()
        XCTAssertEqual(events.count, 4)
    }

    @MainActor func testRapidRouteChangesDiscardStaleAcquisition() async {
        var events: [String] = []
        let routes = PlaybackAudioCoordinator(acquire: { events.append("acquire") }, release: { events.append("release") })
        routes.setLocalPlayback(true)
        routes.setLocalPlayback(false)
        await routes.shutdown()
        XCTAssertFalse(events.contains("acquire"))
    }

    @MainActor func testFailedRestorationCanBeRetriedBeforeOwnershipEnds() async {
        struct Failure: Error {}
        var attempts = 0
        let routes = PlaybackAudioCoordinator(acquire: {}, release: {
            attempts += 1
            if attempts == 1 { throw Failure() }
        })
        await routes.shutdown()
        XCTAssertFalse(routes.restorationSucceeded)
        await routes.shutdown()
        XCTAssertTrue(routes.restorationSucceeded)
        XCTAssertEqual(attempts, 2)
    }

    @MainActor func testAcquisitionFinishesBeforeShutdownRelease() async {
        var events: [String] = []
        let routes = PlaybackAudioCoordinator(acquire: {
            events.append("begin")
            await Task.yield()
            events.append("acquired")
        }, release: { events.append("released") })
        routes.setLocalPlayback(true)
        while events.isEmpty { await Task.yield() }
        await routes.shutdown()
        XCTAssertEqual(events, ["begin", "acquired", "released"])
    }

    @MainActor func testClosingCatalogCancelsLateResultWithOldPlaybackRemaining() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = CatalogTestWindow()
        let launcher = WatchLauncher(app: app, window: window)
        let old = AppDelegate(config: Config(contentID: "offline", title: "Offline", url: "", certificateUrl: "", licenseUrl: "", licenseToken: ""))
        old.window = CatalogTestWindow()
        old.stopPlayback()
        launcher.active = old
        var continuation: CheckedContinuation<WatchCatalogResult, Never>?
        var choices = 0
        var starts = 0
        launcher.fetchCatalog = { await withCheckedContinuation { continuation = $0 } }
        launcher.selectItem = { items, _ in choices += 1; return items.first }
        launcher.beginPlayback = { _ in starts += 1 }
        launcher.load(forceChooser: true)
        while continuation == nil { await Task.yield() }
        let pending = launcher.task
        window.close()
        XCTAssertTrue(pending?.isCancelled == true)
        continuation?.resume(returning: WatchCatalogResult(items: [Self.catalogItem], warnings: []))
        await pending?.value
        XCTAssertEqual(choices, 0)
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(launcher.active === old)
    }

    @MainActor func testSuccessfulLoadingCloseDoesNotCancelPlayback() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = CatalogTestWindow()
        let launcher = WatchLauncher(app: app, window: window)
        launcher.fetchCatalog = { WatchCatalogResult(items: [Self.catalogItem], warnings: []) }
        launcher.selectItem = { items, _ in items.first }
        var starts = 0
        launcher.beginPlayback = { delegate in
            starts += 1
            delegate.onPlaybackStarted?()
            XCTAssertFalse(delegate.isStopped)
            XCTAssertFalse(Task.isCancelled)
        }
        launcher.load()
        await launcher.task?.value
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(launcher.isCancelled)
        XCTAssertFalse(launcher.active?.isStopped ?? true)
    }

    @MainActor func testRestartIgnoresOldCatalogGeneration() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let launcher = WatchLauncher(app: app, window: CatalogTestWindow())
        var continuation: CheckedContinuation<WatchCatalogResult, Never>?
        launcher.fetchCatalog = { await withCheckedContinuation { continuation = $0 } }
        var starts = 0
        launcher.beginPlayback = { _ in starts += 1 }
        launcher.load()
        while continuation == nil { await Task.yield() }
        let oldTask = launcher.task
        launcher.cancel()
        launcher.load(previous: Self.catalogItem)
        await launcher.task?.value
        continuation?.resume(returning: WatchCatalogResult(items: [Self.catalogItem], warnings: []))
        await oldTask?.value
        XCTAssertEqual(starts, 1)
        XCTAssertFalse(launcher.isCancelled)
        launcher.window.close()
        XCTAssertTrue(launcher.active?.isStopped == true)
    }

    @MainActor func testCloseDuringSelectionPreventsPlayback() async {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let window = CatalogTestWindow()
        let launcher = WatchLauncher(app: app, window: window)
        launcher.fetchCatalog = { WatchCatalogResult(items: [Self.catalogItem], warnings: []) }
        launcher.selectItem = { items, _ in window.close(); return items.first }
        var starts = 0
        launcher.beginPlayback = { _ in starts += 1 }
        launcher.load()
        await launcher.task?.value
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(launcher.isCancelled)
    }

    private static var catalogItem: WatchItem {
        WatchItem(choice: WatchChoice(id: "offline", title: "Offline", kind: .liveEvent, isLive: true), contentID: "offline", channelID: nil)
    }

    func testSmokeModeIsExplicitAndWinsOverNoStart() {
        XCTAssertEqual(playerLaunchMode(arguments: ["app", "--smoke-test", "--no-start"]), .smoke)
        XCTAssertEqual(playerLaunchMode(arguments: ["app", "--no-start"]), .noStart)
        XCTAssertEqual(playerLaunchMode(arguments: ["app"]), .normal)
    }
}
