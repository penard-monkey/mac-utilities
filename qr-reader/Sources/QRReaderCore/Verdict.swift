import Foundation

public struct DetailRow: Equatable {
    public let label: String
    public let value: String
    public let secret: Bool
    public init(_ label: String, _ value: String, secret: Bool = false) {
        self.label = label; self.value = value; self.secret = secret
    }
}

/// Everything the approval window needs, and nothing it has to recompute.
///
/// `display` is the exact string the window shows. When `openURL` is non-nil it
/// was built from the same parse — the window must never re-parse `display` or
/// normalise it before opening, or what was approved stops matching what happens.
public struct Verdict {
    public let kind: PayloadKind
    public let title: String
    public let actionLabel: String?
    public let display: String
    public let host: String?
    public let openability: Openability
    public let openURL: URL?
    public let flags: [RiskFlag]
    public let details: [DetailRow]
    public let typeName: String

    public var worstSeverity: RiskFlag.Severity? { flags.map(\.severity).max() }
    public var isOpenable: Bool { openability != .copyOnly && openURL != nil }
}

public enum Classifier {
    public static func verdict(for text: String) -> Verdict {
        build(PayloadParser.parse(text), raw: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func verdict(for data: Data) -> Verdict {
        let kind = PayloadParser.parse(data)
        if case .binary = kind { return build(kind, raw: "") }
        return build(kind, raw: String(data: data, encoding: .utf8) ?? "")
    }

    static func build(_ kind: PayloadKind, raw: String) -> Verdict {
        let flags = Risk.flags(for: kind, raw: raw)

        switch kind {
        case .web(let url):
            // Foundation normalises as it parses: a Cyrillic host becomes
            // punycode, spaces become %20. When that changes the string, the
            // window has to say so — otherwise it shows one thing and opens
            // another, which is the whole failure this app exists to prevent.
            var webFlags = flags
            var details = webDetails(url)
            if !raw.isEmpty, url.absoluteString != raw {
                details.insert(DetailRow("Opens as", url.absoluteString), at: 0)
                webFlags.insert(RiskFlag(.caution, "Rewritten when opened",
                                         "What this code says and what gets opened are not the same text. It will open as \(url.absoluteString)"),
                                at: 0)
            }
            return Verdict(kind: kind, title: "Open this link?", actionLabel: "Open Link",
                           display: raw, host: url.host, openability: .open, openURL: url,
                           flags: webFlags, details: details, typeName: "web")

        case .contact(let url):
            let scheme = (url.scheme ?? "").lowercased()
            let titles = ["mailto": "Start an email?", "tel": "Place a call?",
                          "sms": "Send a message?", "facetime": "Start a FaceTime call?"]
            return Verdict(kind: kind, title: titles[scheme] ?? "Open this?", actionLabel: "Continue",
                           display: raw, host: nil, openability: .open, openURL: url,
                           flags: flags, details: [DetailRow("To", url.opaqueTarget)], typeName: "contact")

        case .location(let url):
            return Verdict(kind: kind, title: "Open this location?", actionLabel: "Open in Maps",
                           display: raw, host: nil, openability: .open, openURL: url,
                           flags: flags, details: [DetailRow("Location", url.opaqueTarget)], typeName: "location")

        case .wifi(let credentials):
            var details = [DetailRow("Network", credentials.ssid),
                           DetailRow("Security", credentials.security ?? "none")]
            if let password = credentials.password {
                details.append(DetailRow("Password", password, secret: true))
            }
            if credentials.hidden { details.append(DetailRow("Hidden network", "yes")) }
            return Verdict(kind: kind, title: "Wi-Fi network", actionLabel: nil,
                           display: "Wi-Fi: \(credentials.ssid)", host: nil,
                           openability: .copyOnly, openURL: nil, flags: flags,
                           details: details, typeName: "wifi")

        case .otp(let seed):
            return Verdict(kind: kind, title: "Authenticator seed — not opened", actionLabel: nil,
                           display: maskedOTP(raw), host: nil, openability: .copyOnly, openURL: nil,
                           flags: flags,
                           details: [DetailRow("Type", seed.kind.uppercased()),
                                     DetailRow("Account", seed.label),
                                     DetailRow("Issuer", seed.issuer ?? "unknown")],
                           typeName: "otp")

        case .card(let text):
            return Verdict(kind: kind, title: "Contact card", actionLabel: nil,
                           display: text, host: nil, openability: .copyOnly, openURL: nil,
                           flags: flags, details: [], typeName: "card")

        case .blocked(let url):
            return Verdict(kind: kind, title: "Refused: \(url.scheme ?? "unknown"):", actionLabel: nil,
                           display: raw, host: url.host, openability: .copyOnly, openURL: nil,
                           flags: flags, details: [], typeName: "blocked")

        case .custom(let url):
            return Verdict(kind: kind, title: "Hand this to another app?", actionLabel: "Open Anyway",
                           display: raw, host: url.host, openability: .confirmTwice, openURL: url,
                           flags: flags,
                           details: [DetailRow("Scheme", (url.scheme ?? "") + ":")],
                           typeName: "custom")

        case .text(let text):
            return Verdict(kind: kind, title: "Plain text", actionLabel: nil,
                           display: text, host: nil, openability: .copyOnly, openURL: nil,
                           flags: flags, details: [DetailRow("Length", "\(text.count) characters")],
                           typeName: "text")

        case .binary(let data):
            return Verdict(kind: kind, title: "Binary payload", actionLabel: nil,
                           display: data.hexPreview, host: nil, openability: .copyOnly, openURL: nil,
                           flags: flags, details: [DetailRow("Size", "\(data.count) bytes")],
                           typeName: "binary")
        }
    }

    static func webDetails(_ url: URL) -> [DetailRow] {
        var rows = [DetailRow("Host", url.host ?? "?")]
        if let host = url.host {
            rows.append(DetailRow("Domain", Risk.registrableDomain(of: host)))
            if let decoded = Punycode.decodeHost(host) { rows.append(DetailRow("Reads as", decoded)) }
        }
        if let port = url.port { rows.append(DetailRow("Port", "\(port)")) }
        rows.append(DetailRow("Path", url.path.isEmpty ? "/" : url.path))
        if let query = url.query { rows.append(DetailRow("Query", query)) }
        return rows
    }

    /// Never put a live OTP secret on screen.
    static func maskedOTP(_ raw: String) -> String {
        guard var components = URLComponents(string: raw), let items = components.queryItems else { return raw }
        components.queryItems = items.map { item in
            ["secret", "key"].contains(item.name.lowercased())
                ? URLQueryItem(name: item.name, value: "••••••••")
                : item
        }
        return components.string ?? raw
    }
}

extension URL {
    /// The part after the scheme for non-hierarchical URLs (mailto:, tel:, geo:).
    var opaqueTarget: String {
        guard let scheme = scheme else { return absoluteString }
        var rest = absoluteString.dropFirst(scheme.count + 1)
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        return String(rest)
    }
}

extension Data {
    var hexPreview: String {
        let head = prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
        return count > 16 ? head + " …" : head
    }
}
