import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

expect(LivePlaybackState(lag: 1.5) == .live, "1.5 seconds is live")
expect(LivePlaybackState(lag: 3.0) == .live, "3 seconds is live")
expect(LivePlaybackState(lag: 3.01) == .behindLive, "more than 3 seconds is behind live")
expect(abs(adjustedVolume(current: 0.5, scrollingDeltaY: 1) - 0.55) < 0.001, "scroll up raises volume")
expect(abs(adjustedVolume(current: 0.5, scrollingDeltaY: -1) - 0.45) < 0.001, "scroll down lowers volume")
expect(adjustedVolume(current: 0.99, scrollingDeltaY: 20) == 1, "volume clamps high")
expect(adjustedVolume(current: 0.01, scrollingDeltaY: -20) == 0, "volume clamps low")
expect(replayTarget(current: 100, seekableStart: 0, seconds: 30) == 70, "replay goes back 30 seconds")
expect(replayTarget(current: 10, seekableStart: 5, seconds: 30) == 5, "replay stays in seekable window")
expect(liveLag(current: 95, seekableEnd: 100) == 5, "lag uses seekable end")
expect(liveLag(current: 101, seekableEnd: 100) == 0, "lag cannot be negative")

let redSox4K = WatchChoice(id: "4k", title: "4K: Rays at Red Sox", kind: .liveEvent, isLive: true)
let redSoxHD = WatchChoice(id: "hd", title: "Rays at Boston Red Sox", kind: .liveEvent, isLive: true)
let boxing = WatchChoice(id: "boxing", title: "Team Boxing", kind: .liveEvent, isLive: true)
let linear = WatchChoice(id: "nesn", title: "NESN live channel", kind: .linearChannel, isLive: true)
let replay = WatchChoice(id: "replay", title: "Sat: Game TB at BOS Replay", kind: .replay, isLive: false)
let duplicateReplay = WatchChoice(id: "replay", title: "Duplicate replay tray entry", kind: .replay, isLive: false)
expect(automaticChoice(from: [boxing, redSox4K, redSoxHD, linear]) == redSox4K, "dedicated 4K Red Sox is automatic")
expect(automaticChoice(from: [boxing, linear, replay]) == nil, "non-Red Sox live programming requires chooser")
expect(chooserChoices(from: [replay, linear, boxing, replay]).map(\.id) == ["boxing", "nesn", "replay"], "chooser groups live first and deduplicates stably")
expect(chooserChoices(from: [replay, duplicateReplay]).first?.title == replay.title, "first duplicate catalog entry wins")
expect(isFullGameReplay(title: "Sat, Jul 18: Game TB at BOS Replay"), "full replay recognized")
expect(!isFullGameReplay(title: "BOS vs TB Highlights"), "highlights excluded from full replays")
expect(scrubFraction(current: 30, duration: 120) == 0.25, "VOD scrub fraction")
expect(scrubFraction(current: 150, duration: 120) == 1, "VOD scrub fraction clamps")
expect(scrubTarget(fraction: 0.5, duration: 120) == 60, "VOD scrub target")
print("PlaybackModelTests passed")