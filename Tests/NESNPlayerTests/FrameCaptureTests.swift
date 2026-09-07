import AVFoundation
import CoreGraphics
import CoreImage
import CoreVideo
import ImageIO
#if canImport(XCTest) && !FRAME_CAPTURE_STANDALONE
import XCTest
@testable import NESNPlayer
#else
// CLT-only hosts have no XCTest. Compile this file with FrameCapture.swift
// and -D FRAME_CAPTURE_STANDALONE to exercise the identical assertions.
class XCTestCase {}
private func XCTUnwrap<T>(_ value: T?) throws -> T {
    guard let value else { fatalError("Unexpected nil") }; return value
}
private func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Values differ: \(a) / \(b)") }
private func XCTAssertTrue(_ value: Bool) { precondition(value) }
private func XCTAssertFalse(_ value: Bool) { precondition(!value) }
private func XCTFail(_ message: String) { fatalError(message) }
private func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T, _ check: (Error) -> Void) {
    do { _ = try expression(); fatalError("Expected failure") } catch { check(error) }
}
@main private struct FrameCaptureTestRunner {
    static func main() async throws {
        let tests = FrameCaptureTests()
        try tests.testSDRPNGFullResolutionAndProfileRoundTrip()
        try tests.test16BitTIFFRoundTripDoesNotClaimHDRFromDepth()
        try tests.testPQEitherVerifiedOrExplicitlyRejectedNeverSilentlySDR()
        try tests.testSaveDoesNotOverwriteWithoutConfirmation()
        await tests.testUnapprovedCaptureFailsBeforeOpeningAsset()
        await tests.testUnextractableClearAssetHasSanitizedFailure()
        try tests.testFloatHDRHeadroomIsPreservedOrRejected()
        await tests.testCurrentPlayerAuthorizationAndTimeout()
        try await tests.testCurrentClearHLSHDRExport()
        print(ProcessInfo.processInfo.environment["FRAME_CAPTURE_HLS_URL"] == nil
              ? "FrameCapture: 8 tests passed; HLS integration skipped (set FRAME_CAPTURE_HLS_URL)"
              : "FrameCapture: 9 tests passed including serialized HDR HLS integration")
        if CommandLine.arguments.count == 2 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            do {
                let result = try await FrameCapture.capture(asset: AVURLAsset(url: url), at: .zero, authorized: true)
                let target = url.deletingLastPathComponent().appendingPathComponent("verified-frame.\(result.fileExtension)")
                try FrameCapture.save(result, to: target)
                print("Local fixture: \(result.width)x\(result.height), \(result.bitsPerComponent)-bit, verifiedHDR=\(result.verifiedHDR), \(result.fileExtension)")
            } catch {
                print("Local fixture capture explicitly rejected: \(error.localizedDescription)")
                throw error
            }
        }
    }
}
#endif

final class FrameCaptureTests: XCTestCase {
    @MainActor
    func testCurrentPlayerAuthorizationAndTimeout() async {
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVMutableComposition()))
        player.isMuted = true
        let item = player.currentItem!
        do {
            _ = try await FrameCapture.capture(player: player, authorized: false, timeout: 0.1)
            XCTFail("Authorization required")
        } catch { XCTAssertEqual(error as? FrameCapture.Failure, .notAuthorized) }
        do {
            _ = try await FrameCapture.capture(player: player, authorized: true, timeout: 0.1)
            XCTFail("Empty item cannot yield a frame")
        } catch { XCTAssertTrue(error is FrameCapture.Failure) }
        XCTAssertEqual(item.outputs.count, 0)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.rate, 0)
        let task = Task { try await FrameCapture.capture(player: player, authorized: true, timeout: 1) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation required") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(item.outputs.count, 0)
    }

    /// Opt-in, video-only synthetic fixture on loopback. Never accepts provider URLs.
    /// FRAME_CAPTURE_HLS_URL=.../neutral.m3u8 (320x180 Y723 PQ), optionally
    /// FRAME_CAPTURE_EXPORT=/tmp/.../hls.tiff keeps the actual serialized evidence.
    @MainActor
    func testCurrentClearHLSHDRExport() async throws {
        guard let raw = ProcessInfo.processInfo.environment["FRAME_CAPTURE_HLS_URL"] else { return }
        let url = try XCTUnwrap(URL(string: raw))
        guard url.scheme == "http", url.host == "127.0.0.1", url.lastPathComponent == "neutral.m3u8" else {
            XCTFail("Only the synthetic loopback neutral fixture is permitted"); return
        }
        let player = AVPlayer()
        player.isMuted = true
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.play()
        defer { player.pause(); player.replaceCurrentItem(with: nil) }
        // Attach on demand AFTER playback starts, not during item setup.
        try await Task.sleep(for: .milliseconds(600))
        let rate = player.rate
        let before = player.currentTime()
        let result = try await FrameCapture.capture(player: player, authorized: true, timeout: 8)
        XCTAssertTrue(player.currentItem === item)
        XCTAssertEqual(player.rate, rate)
        XCTAssertTrue(player.isMuted)
        XCTAssertTrue(player.currentTime() >= before)
        XCTAssertEqual(item.outputs.count, 0)
        XCTAssertEqual(result.width, 320)
        XCTAssertEqual(result.height, 180)
        XCTAssertEqual(result.bitsPerComponent, 16)
        XCTAssertTrue(result.verifiedHDR)
        let target = ProcessInfo.processInfo.environment["FRAME_CAPTURE_EXPORT"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        try FrameCapture.save(result, to: target)
        defer { if ProcessInfo.processInfo.environment["FRAME_CAPTURE_EXPORT"] == nil { try? FileManager.default.removeItem(at: target) } }
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(target as CFURL, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertTrue(CGColorSpaceUsesITUR_2100TF(try XCTUnwrap(decoded.colorSpace)))
        if #available(macOS 15.0, *) {
            XCTAssertTrue(abs(decoded.contentHeadroom - 4.92610836) < 0.001)
        }
        let linear = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020))
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        var pixel = [Float](repeating: 0, count: 4)
        context.render(CIImage(cgImage: decoded), toBitmap: &pixel, rowBytes: 16,
                       bounds: CGRect(x: 100, y: 80, width: 1, height: 1), format: .RGBAf, colorSpace: linear)
        // PQ EOTF(Y723) / 203 = 4.946758148, independently calibrated in fixture.
        for value in pixel.prefix(3) { XCTAssertTrue(abs(value - 4.946758148) < 0.02) }
        print("HLS EXPORTED: \(target.path), \(result.width)x\(result.height), 16-bit PQ; decoded linear RGB=\(pixel)")
    }

    private func image(bits: Int, space: CFString = CGColorSpace.sRGB, width: Int = 73, height: Int = 41) throws -> CGImage {
        let color = try XCTUnwrap(CGColorSpace(name: space))
        let flags = CGImageAlphaInfo.noneSkipLast.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: bits,
                                             bytesPerRow: width * 4 * bits / 8, space: color, bitmapInfo: flags))
        context.setFillColor(CGColor(colorSpace: color, components: [0.2, 0.4, 0.8, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    func testSDRPNGFullResolutionAndProfileRoundTrip() throws {
        let input = try image(bits: 8, width: 3840, height: 2160)
        let result = try FrameCapture.encode(input)
        XCTAssertEqual(result.fileExtension, "png")
        XCTAssertFalse(result.verifiedHDR)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(output.width, 3840)
        XCTAssertEqual(output.height, 2160)
        XCTAssertEqual(output.bitsPerComponent, 8)
        XCTAssertEqual(output.colorSpace?.copyICCData(), input.colorSpace?.copyICCData())
    }

    func test16BitTIFFRoundTripDoesNotClaimHDRFromDepth() throws {
        let input = try image(bits: 16)
        let result = try FrameCapture.encode(input)
        XCTAssertEqual(result.fileExtension, "tiff")
        XCTAssertEqual(result.bitsPerComponent, 16)
        XCTAssertFalse(result.verifiedHDR)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary))
        XCTAssertEqual(output.width, input.width)
        XCTAssertEqual(output.height, input.height)
        XCTAssertEqual(output.bitsPerComponent, input.bitsPerComponent)
        XCTAssertEqual(output.colorSpace?.copyICCData(), input.colorSpace?.copyICCData())
    }

    func testPQEitherVerifiedOrExplicitlyRejectedNeverSilentlySDR() throws {
        let input = try image(bits: 16, space: CGColorSpace.itur_2100_PQ)
        do {
            let result = try FrameCapture.encode(input)
            XCTAssertTrue(result.verifiedHDR)
            XCTAssertEqual(result.fileExtension, "tiff")
            XCTAssertEqual(result.bitsPerComponent, 16)
        } catch {
            XCTAssertEqual(error as? FrameCapture.Failure, .preservationUnavailable)
        }
    }

    func testFloatHDRHeadroomIsPreservedOrRejected() throws {
        guard #available(macOS 15.0, *) else { return }
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 8, bitsPerComponent: 32,
            bytesPerRow: 16 * 16, space: space,
            bitmapInfo: CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(colorSpace: space, components: [3, 2, 1, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 8))
        let base = try XCTUnwrap(context.makeImage())
        let input = try XCTUnwrap(CGImageCreateCopyWithContentHeadroom(3, base))
        do {
            let result = try FrameCapture.encode(input)
            XCTAssertTrue(result.verifiedHDR)
            XCTAssertEqual(result.bitsPerComponent, 32)
            let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
            let output = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary))
            XCTAssertTrue(output.bitmapInfo.contains(.floatComponents))
            XCTAssertEqual(output.contentHeadroom, 3)
            XCTAssertEqual(output.colorSpace?.copyICCData(), input.colorSpace?.copyICCData())
        } catch {
            XCTAssertEqual(error as? FrameCapture.Failure, .preservationUnavailable)
        }
    }

    func testSaveDoesNotOverwriteWithoutConfirmation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("frame.png")
        let result = try FrameCapture.encode(image(bits: 8))
        try FrameCapture.save(result, to: url)
        XCTAssertEqual(try Data(contentsOf: url), result.data)
        XCTAssertThrowsError(try FrameCapture.save(result, to: url)) { error in
            XCTAssertEqual(error as? FrameCapture.Failure, .destinationExists)
        }
        try FrameCapture.save(result, to: url, overwriteConfirmed: true)
        XCTAssertEqual(try Data(contentsOf: url), result.data)
    }

    func testUnapprovedCaptureFailsBeforeOpeningAsset() async {
        do {
            _ = try await FrameCapture.capture(asset: AVMutableComposition(), at: .zero, authorized: false)
            XCTFail("Capture must require authorization")
        } catch {
            XCTAssertEqual(error as? FrameCapture.Failure, .notAuthorized)
        }
    }

    func testUnextractableClearAssetHasSanitizedFailure() async {
        do {
            _ = try await FrameCapture.capture(asset: AVMutableComposition(), at: .zero, authorized: true)
            XCTFail("Empty asset cannot supply a frame")
        } catch {
            XCTAssertEqual(error as? FrameCapture.Failure, .unextractable)
            XCTAssertFalse(error.localizedDescription.contains("URL"))
        }
    }
}
