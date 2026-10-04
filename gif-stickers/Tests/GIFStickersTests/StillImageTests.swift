import XCTest
import ImageIO
import CoreImage
import UniformTypeIdentifiers
@testable import GIFStickers

final class StillImageTests: XCTestCase {
    func image(width: Int = 96, height: Int = 48, transparent: Bool = true) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        if !transparent {
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: width/4, y: height/4, width: width/2, height: height/2))
        return try XCTUnwrap(context.makeImage())
    }
    func write(_ image: CGImage, type: UTType, in directory: URL, orientation: Int = 1) throws -> URL {
        let url = directory.appendingPathComponent("source." + (type.preferredFilenameExtension ?? "image"))
        // HEIF is the container family; ImageIO writes HEVC images through public.heic.
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, (type == .heif ? UTType.heic.identifier : type.identifier) as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return Array(UnsafeBufferPointer(start: bytes, count: image.width*image.height*4))
    }
    func testStillFormatsExportAndReopenWithAlphaAndLibraryImport() throws {
        let directory = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        for type in [UTType.png, .jpeg, .heic, .heif, .tiff] {
            let url = try write(image(), type: type, in: directory)
            let asset = try AnimationAsset(url: url)
            XCTAssertTrue(asset.isStillImage, type.identifier)
            XCTAssertFalse(asset.isVideo)
            XCTAssertEqual(asset.delays.count, 1)
            XCTAssertEqual(asset.size, CGSize(width: 96, height: 48))
            if type == .png || type == .tiff || type == .heic || type == .heif {
                XCTAssertEqual(try rgba(XCTUnwrap(asset.image(at: 0)))[3], 0)
            }
            for fit in [false, true] {
                var framing = Framing.centered(asset.size); framing.fit = fit
                let output = try Encoder.export(asset: asset, framing: framing)
                XCTAssertEqual(output.frameCount, 1)
                XCTAssertLessThanOrEqual(output.data.count, 100000)
                let metadata = try WebPMetadata(data: output.data)
                XCTAssertEqual(metadata.width, 512); XCTAssertEqual(metadata.height, 512)
                XCTAssertTrue(metadata.delays.isEmpty)
                let webp = directory.appendingPathComponent("export.webp")
                try output.data.write(to: webp)
                let reopened = try AnimationAsset(url: webp)
                XCTAssertTrue(reopened.isStillImage)
                let decoded = try XCTUnwrap(reopened.image(at: 0))
                let bytes = try rgba(decoded)
                if fit || type == .png || type == .tiff || type == .heic || type == .heif {
                    XCTAssertEqual(bytes[3], 0, "Source alpha and fit padding survive WebP encoding")
                }
                XCTAssertGreaterThan(bytes[(256*512+256)*4+3], 240)
                let imported = try StickerLibrary(home: directory).importFile(webp)
                XCTAssertEqual(try Data(contentsOf: imported), output.data)
            }
        }
    }
    func testEXIFOrientationAndDecodeSizeCap() throws {
        let directory = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
        context.setFillColor(CGColor(red: 0.8, green: 0.1, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 24))
        let source = try XCTUnwrap(context.makeImage())
        for orientation in [1, 3, 6, 8] {
            let url = try write(source, type: .jpeg, in: directory, orientation: orientation)
            let asset = try AnimationAsset(url: url)
            XCTAssertEqual(asset.size, orientation >= 6 ? CGSize(width: 48, height: 96) : CGSize(width: 96, height: 48))
            // Compare actual pixels to Core Image's EXIF transform, not only dimensions.
            let expected = try XCTUnwrap(CIContext().createCGImage(CIImage(cgImage: source).oriented(forExifOrientation: Int32(orientation)),
                from: CIImage(cgImage: source).oriented(forExifOrientation: Int32(orientation)).extent))
            let actualBytes = try rgba(XCTUnwrap(asset.image(at: 0))), expectedBytes = try rgba(expected)
            let w = expected.width, h = expected.height
            for (x, y) in [(w/4, h/4), (3*w/4, h/4), (w/4, 3*h/4), (3*w/4, 3*h/4)] {
                let pixel = (y*w+x)*4
                for channel in 0..<3 {
                    XCTAssertEqual(Double(actualBytes[pixel+channel]), Double(expectedBytes[pixel+channel]), accuracy: 25)
                }
            }
        }
        let large = try write(image(width: 3000, height: 1500), type: .png, in: directory)
        XCTAssertEqual(try AnimationAsset(url: large).size, CGSize(width: 2048, height: 1024))
    }
    func testAnimatedWebPIsClearlyRejected() throws {
        let directory = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("animated.webp")
        try StickerFixtures.animated.get().write(to: url)
        XCTAssertThrowsError(try AnimationAsset(url: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Animated WebP"))
        }
    }
    func testMaskApplicationPreservesSourceAlphaAndSubjectPixels() throws {
        let source = try image(width: 64, height: 64)
        let mask = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let foreground = CIImage(color: .white).cropped(to: CGRect(x: 16, y: 16, width: 32, height: 32))
        let result = try SubjectCutout.apply(mask: foreground.composited(over: mask), to: source)
        let bytes = try rgba(result)
        XCTAssertEqual(bytes[3], 0)
        XCTAssertEqual(bytes[(16*64+16)*4+3], 0, "The mask must not make transparent source pixels opaque")
        XCTAssertEqual(bytes[(32*64+32)*4+3], 255)
        XCTAssertEqual(result.width, 64); XCTAssertEqual(result.height, 64)
    }
    func testStaticQualityFallbackKeepsOneFrameAndSizeCap() throws {
        let directory = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        var bytes = [UInt8](repeating: 255, count: 512*512*4), seed: UInt32 = 12345
        for pixel in 0..<512*512 {
            for channel in 0..<3 {
                seed = seed &* 1664525 &+ 1013904223
                bytes[pixel*4+channel] = UInt8(truncatingIfNeeded: seed >> 24)
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        let source = try XCTUnwrap(CGImage(width: 512, height: 512, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: 512*4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let asset = try AnimationAsset(url: write(source, type: .png, in: directory))
        let result = try Encoder.export(asset: asset, framing: .centered(asset.size))
        XCTAssertLessThan(result.quality, 90)
        XCTAssertEqual(result.frameCount, 1)
        XCTAssertTrue(try WebPMetadata(data: result.data).delays.isEmpty)
        XCTAssertLessThanOrEqual(result.data.count, 100000)
    }

    @MainActor func testEditorStillCutoutToggleAndReplacement() async throws {
        let directory = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write(image(width: 512, height: 512, transparent: false), type: .png, in: directory)
        let editor = EditorModel(library: LibraryModel(store: StickerLibrary(home: directory)))
        func waitForPreview() async throws {
            let deadline = Date().addingTimeInterval(10)
            while editor.busy && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertFalse(editor.busy)
            XCTAssertNotNil(editor.result)
        }
        editor.load(url)
        try await waitForPreview()
        XCTAssertFalse(editor.cutOutSubject)
        let original = try XCTUnwrap(editor.asset)
        editor.cutOutSubject = true; editor.update()
        try await waitForPreview()
        if editor.error == nil {
            XCTAssertFalse(editor.displayedAsset === original)
            XCTAssertTrue(editor.displayedAsset === (try original.cuttingOutSubject()))
        } else {
            XCTAssertFalse(editor.cutOutSubject)
            XCTAssertTrue(editor.displayedAsset === original)
        }
        editor.cutOutSubject = false; editor.update()
        try await waitForPreview()
        XCTAssertTrue(editor.displayedAsset === original)
        editor.cutOutSubject = true; editor.update()
        // Replace while an obsolete cutout preview is queued: it must never overwrite the new file.
        let replacement = try EngineTests().fixture(directory, frames: 2)
        editor.load(replacement)
        try await waitForPreview()
        XCTAssertFalse(editor.cutOutSubject)
        XCTAssertFalse(try XCTUnwrap(editor.asset).isStillImage)
        XCTAssertEqual(editor.displayedAsset?.url, replacement)
    }

    func testVisionSubjectCutoutAndCache() throws {
        let directory = try StickerFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = try write(image(width: 512, height: 512, transparent: false), type: .png, in: directory)
        let asset = try AnimationAsset(url: url)
        let cutout: AnimationAsset
        do { cutout = try asset.cuttingOutSubject() }
        catch {
            if error.localizedDescription.contains("No subject found") {
                throw XCTSkip("Vision found no instances in this synthetic shape on this runner")
            }
            throw error
        }
        XCTAssertTrue(try asset.cuttingOutSubject() === cutout, "Repeated toggles reuse the cached asset")
        let bytes = try rgba(XCTUnwrap(cutout.image(at: 0)))
        XCTAssertLessThan(bytes[3], 10)
        XCTAssertGreaterThan(bytes[(256*512+256)*4+3], 240)
        XCTAssertEqual(cutout.size, asset.size)
    }
}
