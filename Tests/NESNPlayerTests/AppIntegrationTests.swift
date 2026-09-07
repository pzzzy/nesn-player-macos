import XCTest
import AppKit
@testable import NESNPlayer

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

    func testSmokeModeIsExplicitAndWinsOverNoStart() {
        XCTAssertEqual(playerLaunchMode(arguments: ["app", "--smoke-test", "--no-start"]), .smoke)
        XCTAssertEqual(playerLaunchMode(arguments: ["app", "--no-start"]), .noStart)
        XCTAssertEqual(playerLaunchMode(arguments: ["app"]), .normal)
    }
}
