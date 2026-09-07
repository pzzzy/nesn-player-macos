import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Single native clear-asset still only. Never reads the screen, records video,
/// installs a resource loader, or circumvents content protection.
enum FrameCapture {
    enum Failure: Error, LocalizedError, Equatable {
        case notAuthorized, protectedContent, unextractable, preservationUnavailable
        case destinationExists, saveFailed
        var errorDescription: String? {
            switch self {
            case .notAuthorized: "Screenshot permission has not been granted."
            case .protectedContent: "Screenshots are unavailable for protected content."
            case .unextractable: "This asset cannot provide a native screenshot. Live streams may not support frame extraction."
            case .preservationUnavailable: "A full-quality screenshot cannot be preserved by the available native image encoder."
            case .destinationExists: "A file already exists. Confirm replacement in the save dialog first."
            case .saveFailed: "The screenshot could not be saved to the selected location."
            }
        }
    }

    struct Screenshot: Sendable {
        let data: Data
        let fileExtension: String
        let width: Int
        let height: Int
        let bitsPerComponent: Int
        /// True only after HDR transfer/headroom and the color profile survive decode.
        let verifiedHDR: Bool
        let dynamicRangeNote: String
        var contentType: UTType { fileExtension == "tiff" ? .tiff : .png }
    }

    /// Caller supplies only an asset it is authorized to capture, never a screen.
    /// No changes to the player, audio session, route, rate, or current item.
    /// The UI should show dynamicRangeNote even when capture succeeds.
    static func capture(asset: AVAsset, at time: CMTime, authorized: Bool) async throws -> Screenshot {
        guard authorized else { throw Failure.notAuthorized }
        do {
            guard try await !asset.load(.hasProtectedContent) else { throw Failure.protectedContent }
            guard time.isNumeric, !Task.isCancelled else { throw Failure.unextractable }
            let generator = AVAssetImageGenerator(asset: asset)
            // CGSize.zero is the documented native unscaled size. No resolution cap.
            generator.maximumSize = .zero
            generator.apertureMode = .encodedPixels
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let note: String
            if #available(macOS 15.0, *) {
                generator.dynamicRangePolicy = .matchSource
                note = "Native source-matched frame. AVFoundation currently supplies only SDR frames for HLS; HDR is reported only when verified in the resulting image."
            } else {
                note = "macOS 14 native frame extraction is SDR-only; source HDR cannot be preserved."
            }
            let frame = try await generator.image(at: time)
            try Task.checkCancellation()
            return try encode(frame.image, dynamicRangeNote: note)
        } catch let error as Failure {
            throw error
        } catch {
            // Never expose AVFoundation underlying errors: they may include signed URLs.
            throw Failure.unextractable
        }
    }

    private struct Characteristics {
        let profile: Data
        let hdrTransfer: Bool
        let extended: Bool
        let headroom: Float
        let isFloat: Bool
        var hdr: Bool { hdrTransfer || headroom > 1 }
        init(_ image: CGImage) throws {
            guard let space = image.colorSpace, let icc = space.copyICCData() else {
                throw Failure.preservationUnavailable
            }
            profile = icc as Data
            hdrTransfer = CGColorSpaceUsesITUR_2100TF(space)
            extended = CGColorSpaceUsesExtendedRange(space)
            isFloat = image.bitmapInfo.contains(.floatComponents)
            if #available(macOS 15.0, *) { headroom = image.contentHeadroom }
            else { headroom = 0 }
        }
    }

    /// Lossless ImageIO encoding followed by real decode verification before save.
    /// High bit depth alone is NOT HDR. Unknown/stripped profiles fail closed.
    static func encode(_ image: CGImage, dynamicRangeNote: String = "Native image; dynamic range verified after encoding.") throws -> Screenshot {
        let original = try Characteristics(image)
        let highPrecision = image.bitsPerComponent > 8 || original.hdr || original.extended || original.isFloat
        let type: UTType = highPrecision ? .tiff : .png
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, type.identifier as CFString, 1, nil) else {
            throw Failure.preservationUnavailable
        }
        // TIFF compression 1 is explicitly uncompressed/lossless, never JPEG TIFF.
        let properties: [CFString: Any] = highPrecision ? [kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 1]] : [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let source = CGImageSourceCreateWithData(buffer, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldAllowFloat: true] as CFDictionary) else {
            throw Failure.preservationUnavailable
        }
        let restored = try Characteristics(decoded)
        guard decoded.width == image.width, decoded.height == image.height,
              decoded.bitsPerComponent == image.bitsPerComponent,
              original.profile == restored.profile,
              original.hdrTransfer == restored.hdrTransfer,
              original.extended == restored.extended,
              original.isFloat == restored.isFloat,
              original.headroom == restored.headroom else {
            throw Failure.preservationUnavailable
        }
        return Screenshot(data: buffer as Data, fileExtension: highPrecision ? "tiff" : "png",
                          width: decoded.width, height: decoded.height, bitsPerComponent: decoded.bitsPerComponent,
                          verifiedHDR: original.hdr && restored.hdr, dynamicRangeNote: dynamicRangeNote)
    }

    /// Pass NSSavePanel's chosen URL and set overwriteConfirmed ONLY after the
    /// panel/user explicitly confirms replacement. Default uses exclusive creation
    /// (not an existence-check race). No paths or image content are logged.
    static func save(_ screenshot: Screenshot, to url: URL, overwriteConfirmed: Bool = false) throws {
        guard url.isFileURL else { throw Failure.saveFailed }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try screenshot.data.write(to: url, options: overwriteConfirmed ? [.atomic] : [.withoutOverwriting])
        } catch let error as NSError {
            if error.domain == NSCocoaErrorDomain && error.code == NSFileWriteFileExistsError {
                throw Failure.destinationExists
            }
            throw Failure.saveFailed
        }
    }
}
