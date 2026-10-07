import AppKit
import CoreImage
import QRReaderCore
import Vision

enum DecodedPayload {
    case text(String)
    case bytes(Data)

    var verdict: Verdict {
        switch self {
        case .text(let text): return Classifier.verdict(for: text)
        case .bytes(let data): return Classifier.verdict(for: data)
        }
    }
}

/// Vision is the primary decoder. Phase 0 settled why: on a binary payload
/// CIDetector returns a nil string, indistinguishable from "no code at all",
/// while Vision hands back the bytes. CIDetector stays as a cheap second
/// opinion for the rare image Vision reads as empty.
enum Decoder {

    /// The first Vision request in a process costs ~1.7 s of model loading;
    /// every one after it is ~20 ms. Pay it at launch, not on the first scan.
    static func warm() {
        DispatchQueue.global(qos: .utility).async {
            guard let image = sampleQR() else { return }
            _ = visionPayloads(in: image)
        }
    }

    static func decode(_ image: CGImage) -> [DecodedPayload] {
        let payloads = visionPayloads(in: image)
        return payloads.isEmpty ? detectorPayloads(in: image) : payloads
    }

    private static func visionPayloads(in image: CGImage) -> [DecodedPayload] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do { try handler.perform([request]) } catch { return [] }

        // Vision does not return codes in reading order, so impose one:
        // top to bottom, then left to right, with a tolerance for a row.
        let observations = (request.results ?? []).sorted { a, b in
            let rowA = (1 - a.boundingBox.maxY), rowB = (1 - b.boundingBox.maxY)
            if abs(rowA - rowB) > 0.05 { return rowA < rowB }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        return observations.compactMap { observation in
            if let text = observation.payloadStringValue, !text.isEmpty { return .text(text) }
            // payloadData is API_AVAILABLE(macos(14.0)), i.e. available on every
            // version this app supports — no availability guard, or binary
            // payloads would silently read as "no code found" on macOS 14.
            if let data = observation.payloadData, !data.isEmpty { return .bytes(data) }
            return nil
        }
    }

    private static func detectorPayloads(in image: CGImage) -> [DecodedPayload] {
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: image)) ?? []
        return features.compactMap { feature in
            guard let qr = feature as? CIQRCodeFeature,
                  let message = qr.messageString, !message.isEmpty else { return nil }
            return .text(message)
        }
    }

    private static func sampleQR() -> CGImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data("warm".utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)) else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
