import Foundation

/// How far this app is willing to go with a payload.
public enum Openability: Equatable {
    /// One approving click in the approval window may open it.
    case open
    /// A custom scheme that hands the payload to some local app: needs a
    /// second, separate confirmation.
    case confirmTwice
    /// Never opened by this app, whatever the user clicks.
    case copyOnly
}

public struct WiFiCredentials: Equatable {
    public let ssid: String
    public let security: String?
    public let password: String?
    public let hidden: Bool
}

public struct OTPSeed: Equatable {
    public let kind: String
    public let label: String
    public let issuer: String?
}

public enum PayloadKind: Equatable {
    case web(URL)
    case contact(URL)
    case location(URL)
    case wifi(WiFiCredentials)
    /// An authenticator seed. Opening it would silently add an account to an
    /// authenticator app, so this is never openable.
    case otp(OTPSeed)
    case card(String)
    /// A scheme this app refuses outright: javascript, data, file.
    case blocked(URL)
    /// Some other scheme, i.e. a handoff to an unknown local app.
    case custom(URL)
    case text(String)
    case binary(Data)
}

/// Schemes a single approval may open.
let openableSchemes: Set<String> = ["http", "https", "mailto", "tel", "sms", "facetime", "facetime-audio", "geo", "maps"]
/// Schemes refused no matter what the user clicks.
let blockedSchemes: Set<String> = ["javascript", "data", "file", "vbscript", "about"]

public enum PayloadParser {
    public static func parse(_ text: String) -> PayloadKind {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()

        if upper.hasPrefix("WIFI:") {
            if let credentials = parseWiFi(String(trimmed.dropFirst("WIFI:".count))) {
                return .wifi(credentials)
            }
            return .text(trimmed)
        }
        if upper.hasPrefix("BEGIN:VCARD") || upper.hasPrefix("MECARD:") {
            return .card(trimmed)
        }

        guard let scheme = schemePrefix(of: trimmed) else { return .text(trimmed) }

        // Prose is full of colons ("Notes: 10:30 standup" parses as scheme
        // "Notes"). A scheme we do not recognise therefore has to look like a
        // URL: no whitespace, and something after the colon. Schemes we do know
        // skip the test, so "javascript: alert(1)" is still caught.
        let remainder = trimmed.dropFirst(scheme.count + 1)
        let recognised = blockedSchemes.contains(scheme)
            || openableSchemes.contains(scheme)
            || scheme == "otpauth"
        if !recognised {
            guard !remainder.isEmpty, !remainder.contains(where: { $0.isWhitespace }) else {
                return .text(trimmed)
            }
        }

        guard let url = URL(string: trimmed) ?? syntheticURL(scheme: scheme, when: recognised) else {
            return .text(trimmed)
        }

        if blockedSchemes.contains(scheme) { return .blocked(url) }
        if scheme == "otpauth" {
            return .otp(parseOTP(url))
        }
        switch scheme {
        case "http", "https":
            // A URL with no host is not something we can reason about safely.
            return (url.host?.isEmpty == false) ? .web(url) : .text(trimmed)
        case "mailto", "tel", "sms", "facetime", "facetime-audio":
            return .contact(url)
        case "geo", "maps":
            return .location(url)
        default:
            return .custom(url)
        }
    }

    public static func parse(_ data: Data) -> PayloadKind {
        if let text = String(data: data, encoding: .utf8), !text.isEmpty,
           !text.unicodeScalars.contains(where: { $0.value == 0 }) {
            return parse(text)
        }
        return .binary(data)
    }

    /// A refused scheme must stay refused even if Foundation cannot parse the rest.
    static func syntheticURL(scheme: String, when recognised: Bool) -> URL? {
        recognised ? URL(string: scheme + ":") : nil
    }

    /// The scheme only if it is well formed; avoids treating "Notes: 10:30" as a scheme.
    static func schemePrefix(of text: String) -> String? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let candidate = String(text[text.startIndex..<colon]).lowercased()
        guard !candidate.isEmpty, candidate.count <= 32,
              let first = candidate.first, first.isLetter,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return candidate
    }

    /// `WIFI:S:<ssid>;T:WPA;P:<password>;H:true;;` with backslash escaping.
    static func parseWiFi(_ body: String) -> WiFiCredentials? {
        var fields: [String: String] = [:]
        var key = "", value = "", readingKey = true, escaped = false
        func flush() {
            if !key.isEmpty { fields[key.uppercased()] = value }
            key = ""; value = ""; readingKey = true
        }
        for character in body {
            if escaped {
                if readingKey { key.append(character) } else { value.append(character) }
                escaped = false
                continue
            }
            switch character {
            case "\\": escaped = true
            case ":" where readingKey: readingKey = false
            case ";": flush()
            default: if readingKey { key.append(character) } else { value.append(character) }
            }
        }
        flush()
        guard let ssid = fields["S"], !ssid.isEmpty else { return nil }
        let hidden = (fields["H"] ?? "").lowercased() == "true"
        let password = (fields["P"]?.isEmpty == false) ? fields["P"] : nil
        let security = (fields["T"]?.isEmpty == false) ? fields["T"] : nil
        return WiFiCredentials(ssid: ssid, security: security, password: password, hidden: hidden)
    }

    static func parseOTP(_ url: URL) -> OTPSeed {
        let kind = (url.host ?? "totp").lowercased()
        var label = url.path
        if label.hasPrefix("/") { label.removeFirst() }
        let issuer = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name.lowercased() == "issuer" })?.value
        return OTPSeed(kind: kind, label: label.isEmpty ? "(unnamed)" : label, issuer: issuer)
    }
}
