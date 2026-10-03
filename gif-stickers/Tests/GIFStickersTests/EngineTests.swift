import XCTest
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
@testable import GIFStickers

final class EngineTests: XCTestCase {
    func fixture(_ directory: URL, frames: Int, delay: Double = 0.1) throws -> URL {
        let url = directory.appendingPathComponent("sample.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, frames, nil))
        for index in 0..<frames {
            let context = try XCTUnwrap(CGContext(data: nil, width: 96, height: 48, bitsPerComponent: 8,
                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: Double(index%3)/2, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 96, height: 48))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: index%80, y: 5, width: 12, height: 20))
            let image = try XCTUnwrap(context.makeImage())
            CGImageDestinationAddImage(destination, image,
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }
    /// Writes an H.264 video like the "GIFs" sites serve: no audio, a moving bar on a
    /// changing background. `transform` mimics a phone recording stored sideways.
    func videoFixture(_ directory: URL, name: String, fileType: AVFileType, width: Int = 160, height: Int = 90,
                      fps: Int32 = 12, frames: Int = 12, transform: CGAffineTransform = .identity) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: fileType)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height])
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            let pool = try XCTUnwrap(adaptor.pixelBufferPool)
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let context = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            context.setFillColor(CGColor(red: Double(index%3)/2, green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: (index*7)%(width-12), y: 5, width: 12, height: height/2))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            XCTAssertTrue(adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: fps)))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        return url
    }
    func temporary(_ work: (URL) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        try work(url)
    }
    func muxInfo(_ data: Data, directory: URL) throws -> String {
        let url = directory.appendingPathComponent("result.webp")
        try data.write(to: url)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/webpmux")
        process.arguments = ["-info", url.path]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return String(decoding: output, as: UTF8.self)
    }
    func testAnimatedCropAndFit() throws {
        try temporary { directory in
            let url = try fixture(directory, frames: 8)
            let asset = try AnimationAsset(url: url)
            var frame = Framing.centered(asset.size)
            XCTAssertEqual(frame.side, 48)
            for fit in [false, true] {
                frame.fit = fit
                let output = try Encoder.export(url: url, framing: frame)
                XCTAssertLessThanOrEqual(output.data.count, 500000)
                XCTAssertLessThanOrEqual(output.duration, 10)
                let info = try muxInfo(output.data, directory: directory)
                XCTAssertTrue(info.contains("Canvas size: 512 x 512"))
                XCTAssertTrue(info.contains("animation"))
                XCTAssertTrue(info.contains("Loop Count : 0"))
                if fit {
                    let image = try frame.render(XCTUnwrap(asset.image(at: 0)))
                    let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
                    XCTAssertEqual(bytes[3], 0, "Fit must retain transparent padding")
                }
            }
        }
    }
    func testStaticCapAndLongTrim() throws {
        try temporary { directory in
            let staticURL = try fixture(directory, frames: 1)
            let asset = try AnimationAsset(url: staticURL)
            let output = try Encoder.export(url: staticURL, framing: .centered(asset.size))
            XCTAssertLessThanOrEqual(output.data.count, 100000)
            XCTAssertEqual(output.frameCount, 1)
            let longURL = try fixture(directory, frames: 12, delay: 1)
            let long = try Encoder.export(url: longURL, framing: .centered(asset.size))
            XCTAssertTrue(long.trimmed); XCTAssertEqual(long.duration, 10)
            let info = try muxInfo(long.data, directory: directory)
            let delays = info.split(separator: "\n").compactMap { line -> Int? in
                let cells = line.split(whereSeparator: { $0 == " " })
                guard cells.count >= 8, cells[0].hasSuffix(":"), Int(cells[0].dropLast()) != nil else { return nil }
                return Int(cells[6])
            }
            XCTAssertEqual(delays.reduce(0,+), 10000)
            XCTAssertTrue(delays.allSatisfy { $0 >= 8 })
        }
    }
    func testAdaptiveQualityAndCancellation() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("noise.gif")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 24, nil))
            var seed: UInt32 = 12345
            for _ in 0..<24 {
                var bytes = [UInt8](repeating: 255, count: 256*256*4)
                for pixel in 0..<256*256 {
                    for channel in 0..<3 {
                        seed = seed &* 1664525 &+ 1013904223
                        bytes[pixel*4+channel] = UInt8(truncatingIfNeeded: seed >> 24)
                    }
                }
                let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
                let image = try XCTUnwrap(CGImage(width: 256, height: 256, bitsPerComponent: 8,
                    bitsPerPixel: 32, bytesPerRow: 256*4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                CGImageDestinationAddImage(destination, image,
                    [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
            }
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            let output = try Encoder.export(url: url, framing: .centered(CGSize(width: 256, height: 256)))
            XCTAssertLessThanOrEqual(output.data.count, 500000)
            XCTAssertLessThan(output.quality, 90)
            XCTAssertLessThan(output.fps, 20, "Complex input should exercise frame-rate fallback")
            print("Adaptive fixture: " + output.summary)
            let metadata = try WebPMetadata(data: output.data)
            XCTAssertEqual(metadata.width, 512)
            XCTAssertLessThanOrEqual(metadata.delays.reduce(0,+), 10000)
            XCTAssertThrowsError(try Encoder.export(url: url, framing: Framing(), cancelled: { true }))
        }
    }

    func testCropBoundsAndInvalidInput() throws {
        var frame = Framing(x: -20, y: 300, side: 900)
        frame.clamp(to: CGSize(width: 96, height: 48))
        XCTAssertEqual(frame.side, 48); XCTAssertEqual(frame.x, 0); XCTAssertEqual(frame.y, 0)
        XCTAssertThrowsError(try AnimationAsset(url: URL(fileURLWithPath: "/dev/null")))
    }

    func testLoopingVideosExportLikeGIFs() throws {
        try temporary { directory in
            for (name, type) in [("loop.mp4", AVFileType.mp4), ("loop.m4v", AVFileType.m4v), ("loop.mov", AVFileType.mov)] {
                let url = try videoFixture(directory, name: name, fileType: type)
                let asset = try AnimationAsset(url: url)
                XCTAssertTrue(asset.isVideo, name)
                XCTAssertEqual(asset.size, CGSize(width: 160, height: 90), name)
                XCTAssertGreaterThan(asset.delays.count, 1, name)
                XCTAssertEqual(asset.duration, 1, accuracy: 0.1, name)
                XCTAssertNotNil(asset.image(at: asset.delays.count - 1), name)
                var frame = Framing.centered(asset.size)
                XCTAssertEqual(frame.side, 90)
                for fit in [false, true] {
                    frame.fit = fit
                    let output = try Encoder.export(asset: asset, framing: frame)
                    XCTAssertLessThanOrEqual(output.data.count, 500000)
                    XCTAssertFalse(output.trimmed)
                    let info = try muxInfo(output.data, directory: directory)
                    XCTAssertTrue(info.contains("Canvas size: 512 x 512"), name)
                    XCTAssertTrue(info.contains("animation"), name)
                    XCTAssertTrue(info.contains("Loop Count : 0"), name)
                }
            }
        }
    }

    func testRotatedVideoIsUpright() throws {
        try temporary { directory in
            // Stored landscape with a 90° display transform, as a phone records portrait.
            let url = try videoFixture(directory, name: "portrait.mp4", fileType: .mp4,
                                       transform: CGAffineTransform(rotationAngle: .pi/2))
            let asset = try AnimationAsset(url: url)
            XCTAssertEqual(asset.size, CGSize(width: 90, height: 160))
            XCTAssertEqual(Framing.centered(asset.size).side, 90)
        }
    }

    func testLongVideoIsCutAtTenSeconds() throws {
        try temporary { directory in
            let url = try videoFixture(directory, name: "long.mp4", fileType: .mp4, fps: 2, frames: 24)
            let asset = try AnimationAsset(url: url)
            XCTAssertGreaterThan(asset.sourceDuration, 10)
            XCTAssertLessThanOrEqual(asset.duration, 10)
            let output = try Encoder.export(asset: asset, framing: .centered(asset.size))
            XCTAssertTrue(output.trimmed)
            XCTAssertLessThanOrEqual(output.duration, 10)
            XCTAssertTrue(output.summary.contains("trimmed"))
        }
    }

    func testNonMediaIsRejected() throws {
        try temporary { directory in
            let url = directory.appendingPathComponent("notes.mp4")
            try Data("not a video".utf8).write(to: url)
            XCTAssertThrowsError(try AnimationAsset(url: url))
        }
    }
}
