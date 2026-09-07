import Foundation
import AppKit
@preconcurrency import AVFoundation
import QuartzCore

final class EncodeProbe: @unchecked Sendable {
    static let shared = EncodeProbe()
    let lock = NSLock()
    var windows: [[Double]] = []
    func begin() { lock.lock(); windows.append([ProcessInfo.processInfo.systemUptime, Thread.isMainThread ? 1 : 0]); lock.unlock() }
    func end() { lock.lock(); windows[windows.count-1].append(ProcessInfo.processInfo.systemUptime); lock.unlock() }
    func snapshot() -> [[Double]] { lock.lock(); defer { lock.unlock() }; return windows }
}
@MainActor final class Samples {
    var values: [[String: Any]] = []
    let layer: AVPlayerLayer
    init(layer: AVPlayerLayer) { self.layer = layer }
}
@main struct Probe {
    @MainActor static func main() {
        Task { @MainActor in
            do { try await run() } catch { print("PROBE ERROR: \(error)"); exit(2) }
            exit(0)
        }
        RunLoop.main.run()
    }
    @MainActor static func run() async throws {
        let url = URL(fileURLWithPath: CommandLine.arguments[2])
        let asset = AVURLAsset(url: url)
        guard try await asset.loadTracks(withMediaType: .audio).isEmpty else { fatalError("Audio fixture prohibited") }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = false
        let layer = AVPlayerLayer(player: player)
        layer.frame = CGRect(x: 0,y: 0,width: 640,height: 360)
        defer { player.pause(); player.replaceCurrentItem(with: nil); layer.player = nil }
        let samples = Samples(layer: layer)
        let timer = Timer(timeInterval: 0.01, repeats: true) { _ in
            MainActor.assumeIsolated {
                samples.values.append(["host": ProcessInfo.processInfo.systemUptime, "player": player.currentTime().seconds,
                    "mainThread": Thread.isMainThread, "outputSuppression": item.outputs.map { $0.suppressesPlayerRendering },
                    "layerReady": samples.layer.isReadyForDisplay, "rate": player.rate])
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        player.play()
        try await Task.sleep(for: .seconds(1))
        let start = ProcessInfo.processInfo.systemUptime
        var outcome: [String: Any] = [:]
        var captureEnd: Double?
        do {
            let image = try await FrameCapture.capture(player: player, authorized: true, timeout: 8)
            captureEnd = ProcessInfo.processInfo.systemUptime
            outcome = ["width": image.width, "height": image.height, "bits": image.bitsPerComponent, "hdr": image.verifiedHDR, "bytes": image.data.count]
            let folder = URL(fileURLWithPath: CommandLine.arguments[1]).deletingLastPathComponent()
            let date = Date(timeIntervalSince1970: 0)
            let first = try await FrameCapture.saveUniqueTIFF(image, in: folder, date: date)
            let second = try await FrameCapture.saveUniqueTIFF(image, in: folder, date: date)
            outcome["savedUnique"] = first != second
            outcome["savedBytesEqual"] = try Data(contentsOf: first) == image.data && Data(contentsOf: second) == image.data
            outcome["saveNames"] = [first.lastPathComponent, second.lastPathComponent]
        } catch { outcome = ["error": String(describing: error)] }
        let end = captureEnd ?? ProcessInfo.processInfo.systemUptime
        try await Task.sleep(for: .milliseconds(100))
        let result: [String: Any] = ["start": start, "end": end, "samples": samples.values, "encodeWindows": EncodeProbe.shared.snapshot(),
            "outcome": outcome, "remainingOutputs": item.outputs.count, "sameItem": player.currentItem === item,
            "layerPlayerUnchanged": layer.player === player, "layerVerification": "Offscreen AVPlayerLayer only; not proof of presented frames"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys])
        let target = CommandLine.arguments[1]
        try data.write(to: URL(fileURLWithPath: target))
        print("RESULT \(target)")
    }
}
