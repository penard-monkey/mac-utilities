import Foundation

public struct RiskFlag: Equatable {
    public enum Severity: Int, Comparable {
        case note, caution, danger
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }
    public let severity: Severity
    public let label: String
    public let detail: String

    public init(_ severity: Severity, _ label: String, _ detail: String) {
        self.severity = severity; self.label = label; self.detail = detail
    }
}

/// Hosts that hide their real destination by design. Not a blocklist — the
/// approval window just says so, and offers to resolve the chain.
let knownShorteners: Set<String> = [
    "bit.ly", "t.co", "tinyurl.com", "goo.gl", "ow.ly", "is.gd", "buff.ly",
    "rebrand.ly", "cutt.ly", "shorturl.at", "t.ly", "lnkd.in", "s.id",
    "rb.gy", "tiny.cc", "soo.gd", "clck.ru", "v.gd", "qr.ae", "surl.li",
]

/// Multi-level public suffixes common enough to matter here. This is a
/// heuristic, not the Public Suffix List, and is only used for the shortener
/// lookup — the approval window highlights the *whole* host so a wrong guess
/// can never understate the real destination.
let multiLevelSuffixes: Set<String> = [
    "co.uk", "org.uk", "ac.uk", "gov.uk", "co.jp", "or.jp", "ne.jp",
    "com.au", "net.au", "org.au", "com.br", "com.mx", "com.ar", "com.co",
    "co.nz", "co.za", "co.in", "com.tr", "com.cn", "com.tw", "com.hk",
]

public enum Risk {
    /// Characters that can make a string read as something it is not.
    static let deceptiveScalars: Set<UInt32> = [
        0x00AD, 0x200B, 0x200C, 0x200D, 0x200E, 0x200F,
        0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF, 0x061C,
    ]

    enum Script { case latin, cyrillic, greek, other }

    static func script(of scalar: UnicodeScalar) -> Script {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A: return .latin
        case 0x0370...0x03FF, 0x1F00...0x1FFF: return .greek
        case 0x0400...0x04FF, 0x0500...0x052F: return .cyrillic
        default: return .other
        }
    }

    /// The last two labels, honouring the small multi-level suffix list.
    public static func registrableDomain(of host: String) -> String {
        let labels = host.lowercased().split(separator: ".").map(String.init)
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        if multiLevelSuffixes.contains(lastTwo), labels.count >= 3 {
            return labels.suffix(3).joined(separator: ".")
        }
        return lastTwo
    }

    static func isIPLiteral(_ host: String) -> Bool {
        if host.contains(":") { return true }   // IPv6
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let value = Int(part), part.count <= 3, !part.isEmpty else { return false }
            return (0...255).contains(value)
        }
    }

    /// Every check here is local. Nothing in this function touches the network.
    public static func flags(for kind: PayloadKind, raw: String) -> [RiskFlag] {
        var flags: [RiskFlag] = []

        // Deceptive characters matter wherever they appear, not just in the host.
        let deceptive = raw.unicodeScalars.filter { deceptiveScalars.contains($0.value) }
        if !deceptive.isEmpty {
            let names = deceptive.map { String(format: "U+%04X", $0.value) }
            flags.append(RiskFlag(.danger, "Hidden characters",
                                  "Contains invisible or direction-changing characters (\(names.joined(separator: ", "))) that can make this read as something else."))
        }
        if raw.unicodeScalars.contains(where: { $0.value < 0x20 && $0.value != 0x0A && $0.value != 0x0D }) {
            flags.append(RiskFlag(.caution, "Control characters", "Contains non-printing control characters."))
        }
        if raw.localizedCaseInsensitiveContains("%00") {
            flags.append(RiskFlag(.danger, "Encoded null byte",
                                  "Contains %00, which some software treats as the end of the string — what you see may not be what it acts on."))
        }

        switch kind {
        case .web(let url), .custom(let url), .blocked(let url), .contact(let url), .location(let url):
            flags.append(contentsOf: urlFlags(url, kind: kind, raw: raw))
        case .otp(let seed):
            flags.append(RiskFlag(.danger, "Authenticator seed",
                                  "This is a one-time-password secret for \(seed.issuer ?? seed.label). Opening it would add an account to an authenticator app. QR Reader never opens these."))
        case .wifi(let credentials):
            if credentials.password != nil {
                flags.append(RiskFlag(.caution, "Contains a password",
                                      "The Wi-Fi password for \"\(credentials.ssid)\" is in this code. It is hidden until you reveal it and is redacted in history."))
            }
            if (credentials.security ?? "nopass").lowercased() == "nopass" {
                flags.append(RiskFlag(.note, "Open network", "\"\(credentials.ssid)\" has no encryption."))
            }
        case .binary(let data):
            flags.append(RiskFlag(.caution, "Not text",
                                  "\(data.count) bytes that are not valid UTF-8. There is nothing here to open."))
        case .card, .text:
            break
        }
        return flags.sorted { $0.severity > $1.severity }
    }

    private static func urlFlags(_ url: URL, kind: PayloadKind, raw: String) -> [RiskFlag] {
        var flags: [RiskFlag] = []
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let scheme = (url.scheme ?? "").lowercased()

        if case .blocked = kind {
            flags.append(RiskFlag(.danger, "Refused scheme",
                                  "\"\(scheme):\" can run code or hide its real content. QR Reader never opens it."))
        }
        if case .custom = kind {
            flags.append(RiskFlag(.caution, "Unknown app scheme",
                                  "\"\(scheme):\" hands this straight to whichever app claims that scheme. QR Reader cannot tell you what it will do."))
        }

        if let user = components?.user, !user.isEmpty {
            flags.append(RiskFlag(.danger, "Credentials before the host",
                                  "Everything before the @ is a username, not the destination. This connects to \(url.host ?? "?")."))
        }
        guard let host = url.host, !host.isEmpty else { return flags }

        if scheme == "http" {
            flags.append(RiskFlag(.caution, "Not encrypted", "http:// sends this in the clear."))
        }
        if isIPLiteral(host) {
            flags.append(RiskFlag(.caution, "Numeric address", "Goes to the raw address \(host), with no domain name to recognise."))
        }
        if let port = url.port, !((scheme == "https" && port == 443) || (scheme == "http" && port == 80)) {
            flags.append(RiskFlag(.note, "Unusual port", "Connects on port \(port)."))
        }
        if let decoded = Punycode.decodeHost(host) {
            flags.append(RiskFlag(.danger, "Punycode host",
                                  "\(host) is really \"\(decoded)\" — non-Latin characters can imitate a familiar name."))
        }
        for label in host.split(separator: ".") {
            let scripts = Set(label.unicodeScalars.map(script(of:))).subtracting([.other])
            if scripts.count > 1 {
                flags.append(RiskFlag(.danger, "Mixed alphabets",
                                      "\"\(label)\" mixes alphabets, a common way to imitate a familiar name."))
                break
            }
        }
        if knownShorteners.contains(registrableDomain(of: host)) {
            flags.append(RiskFlag(.caution, "Shortened link",
                                  "\(host) hides the real destination. Use Resolve redirects to see where it goes."))
        }
        if raw.count > 300 {
            flags.append(RiskFlag(.note, "Very long", "\(raw.count) characters — read the end, not just the start."))
        }
        return flags
    }
}
