import Foundation
import Network
@testable import GIFStickers

// A loopback-only HTTP server: tests never contact a running daemon or WhatsApp.
final class StubServer {
    struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data
    }
    struct Response {
        var status = 200
        var body: String
        var headers: [String: String] = [:]
        var closeWithoutResponse = false
    }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "gif-stickers.stub-http")
    private let handler: (Request) -> Response
    private(set) var url: URL = URL(string: "http://127.0.0.1")!
    init(handler: @escaping (Request) -> Response) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 3) == .success, let port = listener.port else {
            throw StickerError(message: "Stub listener did not start.")
        }
        url = URL(string: "http://127.0.0.1:\(port.rawValue)")!
    }
    deinit { listener.cancel() }
    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let split = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = lines[0].split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    if parts.count == 2 { headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces) }
                }
                let count = Int(headers["content-length"] ?? "0") ?? 0
                if buffer.count - split.upperBound >= count, first.count >= 2 {
                    let request = Request(method: String(first[0]), path: String(first[1]), headers: headers,
                                          body: buffer.subdata(in: split.upperBound..<(split.upperBound + count)))
                    let result = self.handler(request)
                    if result.closeWithoutResponse { connection.cancel(); return }
                    let body = Data(result.body.utf8)
                    var header = "HTTP/1.1 \(result.status) Stub\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                    for (name, value) in result.headers { header += "\(name): \(value)\r\n" }
                    var response = Data((header + "\r\n").utf8); response.append(body)
                    connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete || error != nil { connection.cancel() }
            else { self.read(connection, buffer: buffer) }
        }
    }
}
