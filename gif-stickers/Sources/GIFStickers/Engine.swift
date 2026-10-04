import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

struct StickerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// One animation, read from a GIF or from a short video ("fake GIF" MP4/M4V/MOV).
/// Immutable after init, so it is shared between the editor and the encoder queue.
final class AnimationAsset: @unchecked Sendable {
    static let maxVideoSide = 1024.0   // decoded video frames; a 512 sticker never needs more
    static let maxVideoFPS = 30.0      // the exporter samples at most 20 fps
    static let maxVideoSeconds = 10.0  // WhatsApp's animated sticker cap
    static let videoTypes: [UTType] = [.mpeg4Movie, .quickTimeMovie, UTType("com.apple.m4v-video")].compactMap { $0 }
    static let openableTypes: [UTType] = [.gif] + videoTypes

    let url: URL
    let size: CGSize
    let delays: [Double]
    /// Length of the whole source. Longer than `duration` when a video was cut at 10 s.
    let sourceDuration: Double
    let isVideo: Bool
    private let source: CGImageSource?
    private let frames: [CGImage]
    var duration: Double { delays.reduce(0, +) }

    init(url: URL) throws {
        self.url = url
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           CGImageSourceGetType(source) as String? == UTType.gif.identifier {
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw StickerError(message: "Choose a readable GIF file.")
            }
            let count = CGImageSourceGetCount(source)
            guard count > 0, count <= 10000, image.width <= 8192, image.height <= 8192 else {
                throw StickerError(message: "This GIF is too large. Use up to 8192 pixels per side and 10,000 frames.")
            }
            self.source = source; frames = []; isVideo = false
            size = CGSize(width: image.width, height: image.height)
            delays = (0..<count).map { index in
                let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any]
                let gif = properties?[kCGImagePropertyGIFDictionary as String] as? [String: Any]
                let delay = gif?[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double
                    ?? gif?[kCGImagePropertyGIFDelayTime as String] as? Double ?? 0.1
                return delay.isFinite ? max(0.008, delay) : 0.1
            }
            sourceDuration = delays.reduce(0, +)
            return
        }
        let video = try Self.decodeVideo(url)
        source = nil; isVideo = true
        frames = video.frames; delays = video.delays; sourceDuration = video.sourceDuration
        size = CGSize(width: video.frames[0].width, height: video.frames[0].height)
    }

    func image(at index: Int) -> CGImage? {
        if let source { return CGImageSourceCreateImageAtIndex(source, index, nil) }
        return frames.indices.contains(index) ? frames[index] : nil
    }

    func frame(at time: Double) -> Int {
        var end = 0.0
        for (index, delay) in delays.enumerated() {
            end += delay
            if time < end { return index }
        }
        return delays.count - 1
    }

    /// Samples the first 10 s at the video's own frame rate (capped at 30 fps), upright and
    /// scaled to at most 1024 px. Audio is ignored.
    private static func decodeVideo(_ url: URL) throws -> (frames: [CGImage], delays: [Double], sourceDuration: Double) {
        let unreadable = StickerError(message: "Choose a GIF or a short video (MP4, M4V or MOV).")
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { throw unreadable }
        let seconds = CMTimeGetSeconds(asset.duration)
        guard seconds.isFinite, seconds > 0 else { throw unreadable }
        let nominal = Double(track.nominalFrameRate)
        let fps = min(maxVideoFPS, nominal.isFinite && nominal > 0 ? nominal : maxVideoFPS)
        let clip = min(seconds, maxVideoSeconds)
        let count = max(1, Int((clip * fps).rounded(.down)))
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxVideoSide, height: maxVideoSide)
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var frames: [CGImage] = []
        frames.reserveCapacity(count)
        for index in 0..<count {
            let time = CMTime(seconds: Double(index) / fps, preferredTimescale: 600)
            do { frames.append(try generator.copyCGImage(at: time, actualTime: nil)) }
            catch {
                // A file can report a little more duration than it has frames; keep what decoded.
                if frames.isEmpty { throw StickerError(message: "Could not decode this video: \(error.localizedDescription)") }
                break
            }
        }
        return (frames, Array(repeating: 1 / fps, count: frames.count), seconds)
    }
}

struct Framing: Equatable {
    var fit = false
    // Top-left coordinates in original image pixels.
    var x = 0.0
    var y = 0.0
    var side = 1.0
    static func centered(_ size: CGSize) -> Framing {
        let side = min(size.width, size.height)
        return Framing(x: (size.width-side)/2, y: (size.height-side)/2, side: side)
    }
    mutating func clamp(to size: CGSize) {
        side = min(max(side, min(16, min(size.width, size.height))), min(size.width, size.height))
        x = min(max(0, x), size.width-side)
        y = min(max(0, y), size.height-side)
    }
    func render(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw StickerError(message: "Could not create sticker canvas.")
        }
        context.interpolationQuality = .high
        if fit {
            let scale = 512 / max(Double(image.width), Double(image.height))
            let w = Double(image.width)*scale, h = Double(image.height)*scale
            context.draw(image, in: CGRect(x: (512-w)/2, y: (512-h)/2, width: w, height: h))
        } else {
            guard let crop = image.cropping(to: CGRect(x: x, y: y, width: side, height: side)) else {
                throw StickerError(message: "Could not crop this frame.")
            }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 512, height: 512))
        }
        guard let result = context.makeImage() else { throw StickerError(message: "Could not render frame.") }
        return result
    }
}

struct ExportResult {
    let data: Data
    let duration: Double
    let fps: Int
    let quality: Int
    let frameCount: Int
    let trimmed: Bool
    var summary: String {
        if frameCount == 1 { return String(format: "%.1f KB · static · quality %d", Double(data.count)/1000, quality) }
        return String(format: "%.1f KB · %.2f s · %d frames · %d fps · quality %d%@", Double(data.count)/1000,
               duration, frameCount, fps, quality, trimmed ? " · trimmed to 10 s" : "")
    }
}

enum Encoder {
    static func tool() throws -> String {
        for path in ["/opt/homebrew/bin/img2webp", "/usr/local/bin/img2webp"] {
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        throw StickerError(message: "WebP encoder is missing. Install it with Homebrew: brew install webp")
    }
    static func export(url: URL, framing: Framing, cancelled: () -> Bool = { false }) throws -> ExportResult {
        if cancelled() { throw CancellationError() }
        return try export(asset: AnimationAsset(url: url), framing: framing, cancelled: cancelled)
    }
    static func export(asset: AnimationAsset, framing: Framing, cancelled: () -> Bool = { false }) throws -> ExportResult {
        func checkCancellation() throws {
            if cancelled() { throw CancellationError() }
        }
        try checkCancellation()
        let executable = try tool()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gif-stickers-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let totalMS = max(8, min(10000, Int((asset.duration*1000).rounded(.down))))
        let animated = asset.delays.count > 1
                for fps in animated ? [20, 15, 10, 6, 3, 1] : [1] {
            let count = animated ? max(2, Int(ceil(Double(totalMS)*Double(fps)/1000))) : 1
            let base = totalMS/count, extra = totalMS%count
            var paths: [(String, Int)] = []
            var timestamp = 0
            for index in 0..<count {
                try checkCancellation()
                let delay = base + (index < extra ? 1 : 0)
                let imageIndex = asset.frame(at: Double(timestamp)/1000)
                guard let image = asset.image(at: imageIndex) else {
                    throw StickerError(message: "Could not decode frame \(imageIndex + 1).")
                }
                let rendered = try framing.render(image)
                let path = directory.appendingPathComponent("frame-\(index).png")
                guard let destination = CGImageDestinationCreateWithURL(path as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                    throw StickerError(message: "Could not create temporary frame.")
                }
                CGImageDestinationAddImage(destination, rendered, nil)
                guard CGImageDestinationFinalize(destination) else { throw StickerError(message: "Could not write temporary frame.") }
                paths.append((path.path, delay)); timestamp += delay
            }
            for quality in [90, 75, 55, 35, 15, 1] {
                try checkCancellation()
                let output = directory.appendingPathComponent("sticker.webp")
                var args = ["-loop", "0", "-min_size", "-lossy", "-q", String(quality), "-m", "4"]
                for (path, delay) in paths { args += ["-d", String(delay), path] }
                args += ["-o", output.path]
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
                // File-backed diagnostics avoid a full-pipe deadlock on large inputs.
                let logURL = directory.appendingPathComponent("encoder.log")
                _ = FileManager.default.createFile(atPath: logURL.path, contents: nil)
                let log = try FileHandle(forWritingTo: logURL)
                process.standardOutput = log; process.standardError = log
                try process.run(); process.waitUntilExit(); try log.close()
                guard process.terminationStatus == 0 else {
                    let diagnostic = (try? String(contentsOf: logURL)) ?? "Unknown error"
                    throw StickerError(message: "WebP encoding failed: \(diagnostic.prefix(1000))")
                }
                let data = try Data(contentsOf: output)
                let metadata = try WebPMetadata(data: data)
                let cap = metadata.delays.isEmpty ? 100000 : 500000
                guard metadata.width == 512, metadata.height == 512,
                      metadata.delays.allSatisfy({ $0 >= 8 }), metadata.delays.reduce(0, +) <= 10000 else {
                    throw StickerError(message: "Encoder produced a file outside the sticker specifications.")
                }
                if data.count <= cap {
                    return ExportResult(data: data, duration: Double(metadata.delays.reduce(0, +))/1000, fps: fps,
                        quality: quality, frameCount: max(1, metadata.delays.count), trimmed: asset.sourceDuration > 10)
                }
            }
        }
        throw StickerError(message: "Could not meet the sticker size limit, even at minimum quality and 1 fps. Try a simpler crop or a shorter animation.")
    }
}

// Validate the encoded container, since identical frames may be merged by img2webp.
struct WebPMetadata {
    let width: Int
    let height: Int
    let delays: [Int]
    init(data: Data) throws {
        let bytes = [UInt8](data)
        func uint(_ offset: Int, _ count: Int) -> Int {
            (0..<count).reduce(0) { $0 | Int(bytes[offset+$1]) << (8*$1) }
        }
        guard bytes.count >= 20, String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WEBP", uint(4, 4) + 8 == bytes.count else {
            throw StickerError(message: "Encoder did not produce a WebP file.")
        }
        var offset = 12, delays: [Int] = [], canvas: (Int, Int)?
        while offset + 8 <= bytes.count {
            let name = String(bytes: bytes[offset..<offset+4], encoding: .ascii)
            let length = uint(offset+4, 4)
            guard length <= bytes.count-offset-8 else { throw StickerError(message: "Incomplete WebP output.") }
            if name == "VP8X", length >= 10 { canvas = (uint(offset+12, 3)+1, uint(offset+15, 3)+1) }
            if name == "ANMF", length >= 16 { delays.append(uint(offset+20, 3)) }
            offset += 8 + length + length%2
        }
        guard offset == bytes.count else { throw StickerError(message: "Incomplete WebP output.") }
        if let canvas { width = canvas.0; height = canvas.1 }
        else if let source = CGImageSourceCreateWithData(data as CFData, nil),
                let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                let w = properties[kCGImagePropertyPixelWidth as String] as? Int,
                let h = properties[kCGImagePropertyPixelHeight as String] as? Int {
            width = w; height = h
        } else { throw StickerError(message: "Cannot validate WebP canvas dimensions.") }
        self.delays = delays
    }
}
