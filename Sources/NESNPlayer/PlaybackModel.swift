import Foundation
import AVFoundation

func configurePlayerForAirPlay(_ player: AVPlayer) {
    player.allowsExternalPlayback = true
}

enum LivePlaybackState: Equatable {
    case live
    case behindLive

    init(lag: Double) {
        self = lag <= 3 ? .live : .behindLive
    }
}

func adjustedVolume(current: Float, scrollingDeltaY: CGFloat) -> Float {
    let delta = Float(scrollingDeltaY) * 0.05
    return min(1, max(0, current + delta))
}

func replayTarget(current: Double, seekableStart: Double, seconds: Double = 30) -> Double {
    max(seekableStart, current - seconds)
}

func liveLag(current: Double, seekableEnd: Double) -> Double {
    max(0, seekableEnd - current)
}

func scrubFraction(current: Double, duration: Double) -> Double {
    guard current.isFinite, duration.isFinite, duration > 0 else { return 0 }
    return min(1, max(0, current / duration))
}

func scrubTarget(fraction: Double, duration: Double) -> Double {
    guard fraction.isFinite, duration.isFinite, duration > 0 else { return 0 }
    return min(1, max(0, fraction)) * duration
}

func preferredOutputSampleRate(isUltraHD: Bool, isLiveContent: Bool) -> Double? {
    isUltraHD && isLiveContent ? 48_000 : nil
}

enum PlaybackPhase: String {
    case loading = "Loading", buffering = "Buffering", playing = "Playing"
    case paused = "Paused", failed = "Playback failed", ended = "Ended"
}

/// User intent is distinct from AVPlayer's temporarily paused/waiting rate.
struct PlaybackIntent {
    private(set) var wantsPlayback = false
    private var terminal: PlaybackPhase?
    var actionLabel: String { wantsPlayback ? "Pause" : "Play" }
    mutating func play() { terminal = nil; wantsPlayback = true }
    mutating func pause() { wantsPlayback = false }
    mutating func toggle() { wantsPlayback ? pause() : play() }
    mutating func fail() { wantsPlayback = false; terminal = .failed }
    mutating func end() { wantsPlayback = false; terminal = .ended }
    func phase(status: AVPlayer.TimeControlStatus) -> PlaybackPhase {
        if let terminal { return terminal }
        guard wantsPlayback else { return .paused }
        return status == .playing ? .playing : .buffering
    }
}

/// A drag previews locally and commits one precise seek on release.
struct ScrubSession {
    private(set) var isActive = false
    private(set) var resumePlayback = false
    private(set) var target: Double?
    mutating func begin(wasPlaying: Bool) {
        guard !isActive else { return }
        isActive = true; resumePlayback = wasPlaying; target = nil
    }
    mutating func update(target: Double) {
        guard isActive, target.isFinite, target >= 0 else { return }
        self.target = target
    }
    mutating func finish() -> Double? {
        guard isActive else { return nil }
        isActive = false
        defer { target = nil }
        return target
    }
    mutating func cancel() { isActive = false; target = nil; resumePlayback = false }
}

func shouldHidePlaybackControls(playing: Bool, scrubbing: Bool, pointerInControls: Bool,
                                focusedControl: Bool, routePickerActive: Bool) -> Bool {
    playing && !scrubbing && !pointerInControls && !focusedControl && !routePickerActive
}
