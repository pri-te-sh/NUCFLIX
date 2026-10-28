import Foundation

/// Xtream Codes panels (Xtream UI, XUI.one, World 8K, etc.) frequently return numbers as strings or ints interchangeably.
struct FlexibleString: Codable, Hashable {
    let value: String

    init(_ value: String = "") {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = ""
        } else if let str = try? container.decode(String.self) {
            self.value = str
        } else if let intVal = try? container.decode(Int.self) {
            self.value = String(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = String(doubleVal)
        } else if let boolVal = try? container.decode(Bool.self) {
            self.value = boolVal ? "1" : "0"
        } else {
            self.value = ""
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct FlexibleInt: Codable, Hashable {
    let value: Int

    init(_ value: Int = 0) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = 0
        } else if let intVal = try? container.decode(Int.self) {
            self.value = intVal
        } else if let str = try? container.decode(String.self), let parsed = Int(str.trimmingCharacters(in: .whitespaces)) {
            self.value = parsed
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = Int(doubleVal)
        } else {
            self.value = 0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct FlexibleDouble: Codable, Hashable {
    let value: Double

    init(_ value: Double = 0.0) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = 0.0
        } else if let doubleVal = try? container.decode(Double.self) {
            self.value = doubleVal
        } else if let intVal = try? container.decode(Int.self) {
            self.value = Double(intVal)
        } else if let str = try? container.decode(String.self),
                  let parsed = Double(str.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) {
            self.value = parsed
        } else {
            self.value = 0.0
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct FlexibleStringArray: Codable, Hashable {
    let values: [String]

    init(_ values: [String] = []) {
        self.values = values
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.values = []
        } else if let arr = try? container.decode([String].self) {
            self.values = arr.filter { !$0.isEmpty }
        } else if let str = try? container.decode(String.self), !str.isEmpty {
            self.values = [str]
        } else {
            self.values = []
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(values)
    }
}

/// Thread-safe memo for `decodedBase64OrSelf` (EPG titles/descriptions are read on every render).
private let base64DecodeCache: NSCache<NSString, NSString> = {
    let cache = NSCache<NSString, NSString>()
    cache.countLimit = 10_000
    return cache
}()

extension String {
    /// Decodes a Base64 encoded string if valid, otherwise returns self.
    var decodedBase64OrSelf: String {
        let key = self as NSString
        if let cached = base64DecodeCache.object(forKey: key) {
            return cached as String
        }
        let result = computeDecodedBase64OrSelf()
        base64DecodeCache.setObject(result as NSString, forKey: key)
        return result
    }

    private func computeDecodedBase64OrSelf() -> String {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let data = Data(base64Encoded: trimmed, options: .ignoreUnknownCharacters),
              let decoded = String(data: data, encoding: .utf8),
              !decoded.isEmpty else {
            return self
        }
        return decoded
    }
}

// MARK: - Smart Xtream Name & Badge Formatter

struct FormattedMediaTitle {
    let cleanTitle: String
    let prefixTag: String?
    let badges: [String]
    let isSectionDivider: Bool
}

/// Reference box so `FormattedMediaTitle` values can live in an `NSCache`.
private final class FormattedMediaTitleBox {
    let value: FormattedMediaTitle
    init(_ value: FormattedMediaTitle) { self.value = value }
}

enum XtreamTextFormatter {
    /// Thread-safe memo (NSCache is safe to use from any thread, e.g. background search index builds).
    private static let cache: NSCache<NSString, FormattedMediaTitleBox> = {
        let cache = NSCache<NSString, FormattedMediaTitleBox>()
        cache.countLimit = 50_000
        return cache
    }()

    /// Compiled once. NSRegularExpression is immutable and thread-safe for matching.
    private static let trailingMetadataRegex = try? NSRegularExpression(pattern: #"(\s*\([A-Za-z0-9\-\s]{2,14}\))+$"#)

    private static let prefixSeparators = ["| ", " | ", " - ", ": "]
    private static let trailingJunk: Set<Character> = ["|", "-", "/", "•", "◉", " "]

    static func format(_ raw: String) -> FormattedMediaTitle {
        let key = raw as NSString
        if let cached = cache.object(forKey: key) {
            return cached.value
        }
        let result = computeFormat(raw)
        cache.setObject(FormattedMediaTitleBox(result), forKey: key)
        return result
    }

    private static func computeFormat(_ raw: String) -> FormattedMediaTitle {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        let hashCount = text.filter { $0 == "#" || $0 == "*" || $0 == "=" }.count
        let isDivider = hashCount >= 4 || text.hasPrefix("###") || text.hasSuffix("###")

        if isDivider {
            let stripped = text
                .replacingOccurrences(of: "#", with: "")
                .replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "=", with: "")
                .letReplaceUnicodeTags()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return FormattedMediaTitle(
                cleanTitle: stripped.isEmpty ? "Featured Section" : stripped,
                prefixTag: nil,
                badges: [],
                isSectionDivider: true
            )
        }

        var badges: [String] = []

        if text.contains("\u{2074}\u{1d37}") || text.contains("4K") || text.contains("UHD") || text.contains("\u{00b3}\u{2078}\u{2074}\u{2070}") {
            badges.append("4K")
        }
        if text.contains("\u{1d30}\u{1d52}\u{02e1}\u{1d47}\u{02b8}") {
            badges.append("DOLBY")
        }
        if text.contains("\u{1d3f}\u{1d2c}\u{1d42}") || text.localizedCaseInsensitiveContains(" RAW") {
            badges.append("RAW")
        }
        if text.contains("\u{1d34}\u{1d30}") || text.hasSuffix(" HD") || text.contains(" HD ") {
            if !badges.contains("4K") {
                badges.append("HD")
            }
        }
        if text.localizedCaseInsensitiveContains("HEVC") {
            badges.append("HEVC")
        }

        text = text.letReplaceUnicodeTags()

        // Extract prefix like "WT| ", "ASIA| ", "IN - ", "IN: ", "SPORTS: ", "4K-NF - "
        var prefixTag: String? = nil
        for sep in prefixSeparators {
            if let range = text.range(of: sep) {
                let candidate = String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if candidate.count >= 2 && candidate.count <= 12 {
                    prefixTag = candidate.replacingOccurrences(of: "|", with: "").trimmingCharacters(in: .whitespaces)
                    text = String(text[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    break
                }
            }
        }

        // Strip trailing parenthetical metadata like "(2021)", "(FR)", "(MULTI-SUBS)"
        // Cheap precheck: the pattern is anchored at the end and requires a closing ")".
        if text.last == ")", let regex = trailingMetadataRegex {
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            text = regex.stringByReplacingMatches(in: text, options: [], range: nsRange, withTemplate: "")
        }

        while let last = text.last, trailingJunk.contains(last) {
            text.removeLast()
        }

        return FormattedMediaTitle(
            cleanTitle: text.isEmpty ? raw : text,
            prefixTag: prefixTag,
            badges: badges,
            isSectionDivider: false
        )
    }
}

private extension String {
    func letReplaceUnicodeTags() -> String {
        self
            .replacingOccurrences(of: "\u{2074}\u{1d37}", with: "")
            .replacingOccurrences(of: "\u{00b3}\u{2078}\u{2074}\u{2070}\u{1d3e}", with: "")
            .replacingOccurrences(of: "\u{1d30}\u{1d52}\u{02e1}\u{1d47}\u{02b8}", with: "")
            .replacingOccurrences(of: "\u{2c7d}\u{1da6}\u{02e2}\u{1da6}\u{1d52}\u{207f}", with: "")
            .replacingOccurrences(of: "\u{1d3f}\u{1d2c}\u{1d42}", with: "")
            .replacingOccurrences(of: "\u{1d34}\u{1d30}", with: "")
            .replacingOccurrences(of: "\u{25c9}", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
