import XCTest
import AVFoundation
import AppKit
@testable import NESNPlayer

private final class FixtureItem: AVPlayerItem, @unchecked Sendable {
    override var duration: CMTime { CMTime(seconds: 100, preferredTimescale: 600) }
    override var seekableTimeRanges: [NSValue] {
        [NSValue(timeRange: CMTimeRange(start: .zero, duration: duration))]
    }
}

private final class FixturePlayer: AVPlayer, @unchecked Sendable {
    private let fixtureItem = FixtureItem(asset: AVMutableComposition())
    // AVFoundation exposes these overrides as nonisolated; fixtures run only on the main actor.
    nonisolated(unsafe) var fixtureTime = 50.0
    nonisolated(unsafe) var playCalls = 0
    nonisolated(unsafe) var seekTargets: [Double] = []
    override var currentItem: AVPlayerItem? { fixtureItem }
    override func currentTime() -> CMTime { CMTime(seconds: fixtureTime, preferredTimescale: 600) }
    override func play() { playCalls += 1 }
    override func pause() {}
    override func seek(to time: CMTime, toleranceBefore: CMTime, toleranceAfter: CMTime) { seekTargets.append(time.seconds) }
}

final class PlaybackLifecycleTests: XCTestCase {
    @MainActor private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor func testVisibleControlsFit320PixelsForLiveAndVOD() {
        for live in [true, false] {
            let player = AVPlayer()
            player.isMuted = true
            let view = PlaybackView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: player, isLiveContent: live)
            defer { view.dispose() }
            view.layoutSubtreeIfNeeded()
            let children = descendants(view)
            for label in ["Capture frame", "Browse sources", "Replay 30 seconds", "Mute or unmute", "Play", "AirPlay to Apple TV"] {
                // AVRoutePickerView supplies its own localized AX label.
                let matches = children.filter { $0.accessibilityLabel() == label || $0.toolTip == label }
                XCTAssertFalse(matches.isEmpty)
                for control in matches {
                    let rect = view.convert(control.bounds, from: control)
                    XCTAssertTrue(rect.width > 0 && rect.height > 0)
                    XCTAssertTrue(view.bounds.contains(rect))
                    XCTAssertFalse(control.isHiddenOrHasHiddenAncestor)
                }
            }
            let buttons = children.compactMap { $0 as? ActionButton }
            for (index, button) in buttons.enumerated() {
                let rect = view.convert(button.bounds, from: button)
                for other in buttons.dropFirst(index + 1) {
                    XCTAssertFalse(rect.intersects(view.convert(other.bounds, from: other)))
                }
            }
            if !live {
                let slider = children.compactMap { $0 as? PlaybackScrubber }.first
                XCTAssertFalse(slider == nil)
                if let slider {
                    let rect = view.convert(slider.bounds, from: slider)
                    XCTAssertTrue(rect.width >= 120 && rect.height > 0)
                    XCTAssertTrue(view.bounds.contains(rect))
                }
            }
        }
    }

    @MainActor func testTransportSymbolsNeverDrawTitlesAfterStateChanges() {
        let view = PlaybackView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: FixturePlayer(), isLiveContent: true)
        defer { view.dispose() }
        let button = descendants(view).compactMap { $0 as? ActionButton }.first { $0.accessibilityLabel() == "Play" }!
        for label in ["Play", "Pause", "Play", "Pause"] {
            if label == "Pause" { view.play() }
            else if button.accessibilityLabel() == "Pause" { button.performClick(nil) }
            XCTAssertEqual(button.accessibilityLabel(), label)
            XCTAssertEqual(button.toolTip, label)
            XCTAssertEqual(button.title, "")
            XCTAssertEqual(button.attributedTitle.string, "")
            XCTAssertEqual(button.imagePosition, .imageOnly)
            XCTAssertFalse(button.image == nil)
        }
    }

    @MainActor func testCaptureFeedbackExpiresWithoutMaskingPlaybackStatus() async throws {
        let view = PlaybackView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: FixturePlayer(), isLiveContent: true)
        defer { view.dispose() }
        view.showCaptureStatus("Saved to Desktop")
        XCTAssertTrue(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Saved to Desktop" })
        try await Task.sleep(for: .seconds(6))
        view.play()
        XCTAssertFalse(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Saved to Desktop" })
    }

    @MainActor func testLiveIndicatorUsesGreenAndDelayedUsesRed() {
        let player = FixturePlayer()
        let view = PlaybackView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: player, isLiveContent: true)
        defer { view.dispose() }
        view.play() // Fixture overrides play; never starts an audio session.
        let button = descendants(view).compactMap { $0 as? NSButton }.first { $0.title == "GO LIVE" }
        XCTAssertFalse(button == nil)
        XCTAssertEqual(button?.contentTintColor, NSColor.systemRed)
        XCTAssertEqual(button?.accessibilityLabel(), "GO LIVE")
        view.layoutSubtreeIfNeeded()
        if let button { XCTAssertTrue(view.bounds.contains(view.convert(button.bounds, from: button))) }
        player.fixtureTime = 99
        view.play()
        XCTAssertEqual(button?.title, "LIVE")
        XCTAssertEqual(button?.contentTintColor, NSColor.systemGreen)
    }

    @MainActor func testBrowseHookAndPausedScrubTeardown() {
        let player = FixturePlayer()
        let view = PlaybackView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: player, isLiveContent: false)
        var choices = 0
        view.onChooseSource = { choices += 1 }
        let browse = descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Browse sources" }
        browse?.performClick(nil)
        XCTAssertEqual(choices, 1)
        let slider = descendants(view).compactMap { $0 as? PlaybackScrubber }.first
        XCTAssertFalse(slider == nil)
        slider?.beginDrag?()
        slider?.doubleValue = 0.5
        if let slider, let action = slider.action { NSApp.sendAction(action, to: slider.target, from: slider) }
        slider?.endDrag?()
        XCTAssertEqual(player.playCalls, 0)
        XCTAssertEqual(player.seekTargets, [50])
        slider?.beginDrag?()
        view.dispose()
        slider?.endDrag?()
        browse?.performClick(nil)
        XCTAssertEqual(choices, 1)
        XCTAssertEqual(player.playCalls, 0)
        XCTAssertEqual(player.seekTargets, [50])
        XCTAssertEqual(view.activeObserverCount, 0)
    }

    @MainActor func testVisibleCaptureInvokesHook() {
        let view = PlaybackView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: AVPlayer(), isLiveContent: false)
        defer { view.dispose() }
        var captures = 0
        view.onCaptureFrame = { captures += 1 }
        let button = descendants(view).compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Capture frame" }
        XCTAssertFalse(button == nil)
        button?.performClick(nil)
        XCTAssertEqual(captures, 1)
        view.dispose()
        button?.performClick(nil)
        XCTAssertEqual(captures, 1)
    }

    @MainActor func testViewDisposalIsIdempotentAndReleasesPlayer() {
        let player = AVPlayer()
        player.isMuted = true
        let view = PlaybackView(frame: NSRect(x: 0, y: 0, width: 320, height: 180), player: player, isLiveContent: false)
        view.dispose()
        view.dispose()
        XCTAssertTrue(view.isDisposed)
        XCTAssertEqual(view.activeObserverCount, 0)
    }

    @MainActor func testStopBeforeStartupIsIdempotent() {
        let delegate = AppDelegate(config: Config(contentID: "offline", title: "Offline", url: "", certificateUrl: "", licenseUrl: "", licenseToken: ""))
        delegate.stopPlayback()
        delegate.stopPlayback()
        XCTAssertTrue(delegate.isStopped)
        XCTAssertEqual(delegate.pendingTaskCount, 0)
    }

    func testBufferingIntentCanBePaused() {
        var state = PlaybackIntent()
        state.play()
        XCTAssertEqual(state.phase(status: .waitingToPlayAtSpecifiedRate), .buffering)
        XCTAssertEqual(state.actionLabel, "Pause")
        state.toggle()
        XCTAssertEqual(state.phase(status: .waitingToPlayAtSpecifiedRate), .paused)
        XCTAssertEqual(state.actionLabel, "Play")
    }

    func testFailureAndEndOverrideIntent() {
        var state = PlaybackIntent()
        state.play()
        state.fail()
        XCTAssertEqual(state.phase(status: .playing), .failed)
        XCTAssertFalse(state.wantsPlayback)
        state.play()
        state.end()
        XCTAssertEqual(state.phase(status: .paused), .ended)
    }

    func testScrubCoalescesAndKeepsPausedIntent() {
        var scrub = ScrubSession()
        scrub.begin(wasPlaying: false)
        for value in [10.0, 20, 30] { scrub.update(target: value) }
        XCTAssertTrue(scrub.isActive)
        XCTAssertEqual(scrub.finish(), 30)
        XCTAssertFalse(scrub.resumePlayback)
        XCTAssertFalse(scrub.isActive)
        XCTAssertNil(scrub.finish())
    }

    func testScrubCancellationDropsPendingSeek() {
        var scrub = ScrubSession()
        scrub.begin(wasPlaying: true)
        scrub.update(target: 30)
        scrub.cancel()
        XCTAssertNil(scrub.finish())
    }

    func testControlsNeverHideDuringInteraction() {
        XCTAssertFalse(shouldHidePlaybackControls(playing: true, scrubbing: true, pointerInControls: false, focusedControl: false, routePickerActive: false))
        XCTAssertFalse(shouldHidePlaybackControls(playing: true, scrubbing: false, pointerInControls: true, focusedControl: false, routePickerActive: false))
        XCTAssertFalse(shouldHidePlaybackControls(playing: true, scrubbing: false, pointerInControls: false, focusedControl: true, routePickerActive: false))
        XCTAssertFalse(shouldHidePlaybackControls(playing: true, scrubbing: false, pointerInControls: false, focusedControl: false, routePickerActive: true))
        XCTAssertTrue(shouldHidePlaybackControls(playing: true, scrubbing: false, pointerInControls: false, focusedControl: false, routePickerActive: false))
    }

    func testInvalidScrubInputNeverProducesNaN() {
        XCTAssertEqual(scrubTarget(fraction: .nan, duration: 100), 0)
    }
}
