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
print("PlaybackModelTests passed")