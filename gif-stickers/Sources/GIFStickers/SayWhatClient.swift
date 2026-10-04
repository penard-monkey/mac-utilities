import Foundation
import CryptoKit

/// Reject redirects: signed bodies and the secret belong only to the local daemon.
private final class LocalSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

struct SendAvailability: Equatable {
    let ready: Bool
    let explanation: String
    static let checking = SendAvailability(ready: false, explanation: "Checking SayWhat…")
}

final class SayWhatClient {
    private let baseURL: URL
    private let secretURL: URL
    private let session: URLSession
    private let now: () -> Date

    init(baseURL: URL = URL(string: "http://127.0.0.1:3220")!,
         secretURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/saywhat/send.secret"),
         now: @escaping () -> Date = Date.init) {
        precondition(baseURL.scheme == "http" && baseURL.host == "127.0.0.1", "SayWhat must use IPv4 loopback")
        self.baseURL = baseURL; self.secretURL = secretURL; self.now = now
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: LocalSessionDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    func availability() async -> SendAvailability {
        guard FileManager.default.isReadableFile(atPath: secretURL.path) else {
            return SendAvailability(ready: false, explanation: "Start SayWhat with signed sending enabled to create send.secret.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 3
        struct Health: Decodable { struct Bridge: Decodable { let ok: Bool }; let gowa: Bridge }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let health = try? JSONDecoder().decode(Health.self, from: data) else {
                return SendAvailability(ready: false, explanation: "SayWhat is not ready. Start its daemon and try Refresh.")
            }
            return health.gowa.ok
                ? SendAvailability(ready: true, explanation: "Sends through SayWhat to your own WhatsApp chat.")
                : SendAvailability(ready: false, explanation: "WhatsApp is disconnected. Pair or reconnect it in SayWhat.")
        } catch {
            return SendAvailability(ready: false, explanation: "SayWhat is unavailable. Start its daemon, then try Refresh.")
        }
    }

    func send(_ data: Data) async throws {
        _ = try StickerValidation.check(data)
        // Read only for a confirmed send, so rotation works without restarting this app.
        guard let secretData = try? Data(contentsOf: secretURL),
              let text = String(data: secretData, encoding: .utf8) else { throw failure("no_secret") }
        let secret = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.utf8.count == 64, secret.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw failure("no_secret")
        }
        let boundary = "gif-stickers-" + UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"kind\"\r\n\r\nsticker\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"sticker.webp\"\r\nContent-Type: image/webp\r\n\r\n".utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let timestamp = String(Int64(now().timeIntervalSince1970))
        var signed = Data((timestamp + ".").utf8); signed.append(body)
        // The daemon's hex text is the key; do not hex-decode it.
        let mac = HMAC<SHA256>.authenticationCode(for: signed, using: SymmetricKey(data: Data(secret.utf8)))
        let signature = "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
        var request = URLRequest(url: baseURL.appendingPathComponent("send"))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue(timestamp, forHTTPHeaderField: "X-Saywhat-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-Saywhat-Signature")
        let reply: (Data, URLResponse)
        do { reply = try await session.data(for: request) }
        catch {
            throw StickerError(message: "The connection to SayWhat was lost. Delivery is uncertain; check your own WhatsApp chat before sending again.")
        }
        struct Reply: Decodable { let ok: Bool; let kind: String?; let code: String? }
        guard let http = reply.1 as? HTTPURLResponse else { throw failure(nil) }
        let result = try? JSONDecoder().decode(Reply.self, from: reply.0)
        guard http.statusCode == 200, result?.ok == true, result?.kind == "sticker" else {
            if http.statusCode == 200 {
                throw StickerError(message: "SayWhat returned an unexpected reply. Delivery is uncertain; check your own WhatsApp chat before sending again.")
            }
            throw failure(result?.code, status: http.statusCode)
        }
    }

    private func failure(_ code: String?, status: Int? = nil) -> StickerError {
        let message: String
        switch code {
        case "bad_request": message = "SayWhat could not read the sticker request. Update both apps and try again."
        case "recipient_not_allowed": message = "SayWhat only allows sending to your own WhatsApp chat. Update both apps."
        case "unknown_kind": message = "SayWhat does not recognize sticker sending. Update its daemon."
        case "unsupported_type", "type_mismatch": message = "SayWhat requires a valid WebP sticker. Choose another file."
        case "gowa_unavailable": message = "SayWhat cannot reach WhatsApp. Reconnect it in SayWhat and try again."
        case "not_logged_in": message = "WhatsApp is not logged in. Pair your device in SayWhat first."
        case "no_secret": message = "SayWhat's send.secret is missing or invalid. Start its daemon with signed sending enabled."
        case "unsigned", "bad_signature": message = "SayWhat could not verify the send signature. Restart its daemon and try again."
        case "stale": message = "SayWhat refused an old timestamp. Check your Mac's clock and try again."
        case "too_large", "sticker_size": message = "The sticker exceeds SayWhat's size limit. Export a smaller sticker."
        case "sticker_dimensions": message = "SayWhat requires a 512 × 512 animated sticker. Export it again."
        case "too_short": message = "SayWhat refused the animation duration. Export the sticker again."
        case "gowa_refused": message = "WhatsApp refused the sticker. Check the connection in SayWhat before trying again."
        default: message = "SayWhat refused the send\(status.map { " (HTTP \($0))" } ?? ""). Update its daemon and try again."
        }
        // Never display or log server error strings, which can contain account data.
        return StickerError(message: message)
    }
}
