import AVFoundation
import CoreGraphics
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
        print("FrameCapture: 7 tests passed (standalone assertions; no XCTest installed)")
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
