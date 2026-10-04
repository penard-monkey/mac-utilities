import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import GIFStickers

enum StickerFixtures {
    static let animated: Result<Data, Error> = Result { try make(frames: 2) }
    static let still: Result<Data, Error> = Result { try make(frames: 1) }
    static func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gif-stickers-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private static func make(frames: Int) throws -> Data {
        let directory = try temporaryHome()
        defer { try? FileManager.default.removeItem(at: directory) }
        let gif = directory.appendingPathComponent("fixture.gif")
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(gif as CFURL, UTType.gif.identifier as CFString, frames, nil))
        for index in 0..<frames {
            let context = try XCTUnwrap(CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: Double(index), green: 0.4, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return try Encoder.export(url: gif, framing: .centered(CGSize(width: 32, height: 32))).data
    }
}
