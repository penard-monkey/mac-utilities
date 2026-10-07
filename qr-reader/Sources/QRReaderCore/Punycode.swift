import Foundation

/// RFC 3492 decoder, just enough to show a user what an `xn--` label really
/// says. Foundation has no public IDNA ToUnicode, and the decoded form is the
/// single most useful homograph defence in the approval window.
enum Punycode {
    private static let base = 36, tmin = 1, tmax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 128

    /// Decodes one DNS label. Returns nil if it is not punycode or is malformed.
    static func decodeLabel(_ label: String) -> String? {
        guard label.count > 4, label.lowercased().hasPrefix("xn--") else { return nil }
        return decode(String(label.dropFirst(4)))
    }

    /// Decodes a whole host, label by label. Returns nil when nothing changed.
    static func decodeHost(_ host: String) -> String? {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        var changed = false
        let decoded = labels.map { label -> String in
            if let unicode = decodeLabel(String(label)) { changed = true; return unicode }
            return String(label)
        }
        return changed ? decoded.joined(separator: ".") : nil
    }

    private static func digit(_ character: Character) -> Int? {
        guard let ascii = character.asciiValue else { return nil }
        switch ascii {
        case 0x30...0x39: return Int(ascii) - 0x30 + 26   // 0-9
        case 0x41...0x5A: return Int(ascii) - 0x41        // A-Z
        case 0x61...0x7A: return Int(ascii) - 0x61        // a-z
        default: return nil
        }
    }

    private static func adapt(_ delta: Int, _ count: Int, _ firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / count
        var k = 0
        while delta > ((base - tmin) * tmax) / 2 {
            delta /= (base - tmin)
            k += base
        }
        return k + ((base - tmin + 1) * delta) / (delta + skew)
    }

    private static func decode(_ input: String) -> String? {
        var output: [UnicodeScalar] = []
        var encoded = input

        if let delimiter = input.lastIndex(of: "-") {
            for character in input[input.startIndex..<delimiter] {
                guard character.isASCII, let scalar = character.unicodeScalars.first else { return nil }
                output.append(scalar)
            }
            encoded = String(input[input.index(after: delimiter)...])
        }

        let characters = Array(encoded)
        guard !characters.isEmpty else { return nil }
        var n = initialN, i = 0, bias = initialBias, position = 0

        while position < characters.count {
            let previousI = i
            var weight = 1, k = base
            while true {
                guard position < characters.count, let digit = digit(characters[position]) else { return nil }
                position += 1
                // Malformed input must not be able to spin or overflow.
                let (product, productOverflow) = digit.multipliedReportingOverflow(by: weight)
                guard !productOverflow else { return nil }
                let (sum, sumOverflow) = i.addingReportingOverflow(product)
                guard !sumOverflow, sum <= 0x7FFFFF else { return nil }
                i = sum
                let threshold = k <= bias ? tmin : (k >= bias + tmax ? tmax : k - bias)
                if digit < threshold { break }
                let (nextWeight, weightOverflow) = weight.multipliedReportingOverflow(by: base - threshold)
                guard !weightOverflow else { return nil }
                weight = nextWeight
                k += base
            }
            let count = output.count + 1
            bias = adapt(i - previousI, count, previousI == 0)
            let (increment, incrementOverflow) = n.addingReportingOverflow(i / count)
            guard !incrementOverflow else { return nil }
            n = increment
            i %= count
            guard n <= 0x10FFFF, let scalar = UnicodeScalar(UInt32(n)), i <= output.count else { return nil }
            output.insert(scalar, at: i)
            i += 1
        }
        var view = String.UnicodeScalarView()
        output.forEach { view.append($0) }
        return String(view)
    }
}
