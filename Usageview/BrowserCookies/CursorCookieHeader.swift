#if os(macOS)
import Foundation

/// Builds Cursor API `Cookie` headers from browser cookies (session names only when possible).
enum CursorCookieHeader {
    static let sessionCookieNames: Set<String> = [
        "WorkosCursorSessionToken",
        "__Secure-next-auth.session-token",
        "next-auth.session-token",
        "wos-session",
        "__Secure-wos-session",
        "authjs.session-token",
        "__Secure-authjs.session-token",
    ]

    static func make(from cookies: [HTTPCookie]) -> String {
        let sessionOnly = cookies.filter { sessionCookieNames.contains($0.name) }
        let use = sessionOnly.isEmpty ? cookies : sessionOnly
        return use.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    static func make(from rawHeader: String) -> String {
        if let filtered = CookieHeaderNormalizer.filteredHeader(from: rawHeader, allowedNames: sessionCookieNames) {
            return filtered
        }
        let trimmed = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("=") {
            return CookieHeaderNormalizer.normalize(trimmed) ?? trimmed
        }
        return "WorkosCursorSessionToken=\(trimmed)"
    }
}
#endif
