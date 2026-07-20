import Foundation

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
    guard duration.isFinite, duration > 0 else { return 0 }
    return min(1, max(0, fraction)) * duration
}
