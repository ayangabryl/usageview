import Foundation

/// Normalizes pasted DevTools / curl cookie headers (CodexBar pattern).
enum CookieHeaderNormalizer {
    private static let headerPatterns: [String] = [
        #"(?i)-H\s*'Cookie:\s*([^']+)'"#,
        #"(?i)-H\s*\"Cookie:\s*([^\"]+)\""#,
        #"(?i)\bcookie:\s*'([^']+)'"#,
        #"(?i)\bcookie:\s*\"([^\"]+)\""#,
        #"(?i)\bcookie:\s*([^\r\n]+)"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s*'([^']+)'"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s*\"([^\"]+)\""#,
        #"(?i)(?:^|\s)-b([^\s=]+=[^\s]+)"#,
        #"(?i)(?:^|\s)(?:--cookie|-b)\s+([^\s]+)"#,
    ]

    static func normalize(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        if let extracted = extractHeader(from: value) {
            value = extracted
        }

        value = stripCookiePrefix(value)
        value = stripWrappingQuotes(value)
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)

        return value.isEmpty ? nil : value
    }

    static func pairs(from raw: String) -> [(name: String, value: String)] {
        guard let normalized = normalize(raw) else { return [] }
        var results: [(name: String, value: String)] = []
        results.reserveCapacity(6)

        for part in normalized.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let equalsIndex = trimmed.firstIndex(of: "=")
            else { continue }
            let name = trimmed[..<equalsIndex].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed[trimmed.index(after: equalsIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            results.append((name: String(name), value: String(value)))
        }

        return results
    }

    static func filteredHeader(from raw: String?, allowedNames: Set<String>) -> String? {
        let filtered = pairs(from: raw ?? "").filter { allowedNames.contains($0.name) }
        guard !filtered.isEmpty else { return nil }
        return filtered.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private static func extractHeader(from raw: String) -> String? {
        for pattern in headerPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { continue }
            let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let match = regex.firstMatch(in: raw, options: [], range: range),
                  match.numberOfRanges >= 2,
                  let captureRange = Range(match.range(at: 1), in: raw)
            else { continue }
            let captured = raw[captureRange].trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty { return String(captured) }
        }
        return nil
    }

    private static func stripCookiePrefix(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("cookie:") else { return trimmed }
        let idx = trimmed.index(trimmed.startIndex, offsetBy: "cookie:".count)
        return String(trimmed[idx...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripWrappingQuotes(_ raw: String) -> String {
        var value = raw
        if (value.hasPrefix("'") && value.hasSuffix("'")) || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
