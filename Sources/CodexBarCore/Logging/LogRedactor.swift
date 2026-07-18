import Foundation

public enum LogRedactor {
    private static let fallbackRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "$^", options: [])
        } catch {
            fatalError("Failed to build fallback regex: \(error)")
        }
    }()

    private static let emailRegex = Self.makeRegex(
        pattern: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
        options: [.caseInsensitive])
    private static let cookieHeaderRegex = Self.makeRegex(
        pattern: #"(?i)(cookie\s*:\s*)([^\r\n]+)"#)
    #if os(macOS)
    private static let cookieDiagnosticRegex = Self.makeRegex(
        pattern: #"(?i)((?:cookies being sent|set-cookie headers received)\s*:\s*)([^\r\n]+)"#)
    #endif
    private static let authorizationRegex = Self.makeRegex(
        pattern: #"(?i)(authorization\s*:\s*)([^\r\n]+)"#)
    private static let sensitiveHeaderRegex = Self.makeRegex(
        pattern: #"(?im)^(\s*(?:x-api-key|api-key|access-token|refresh-token|"# +
            #"client-secret|session-token|proxy-authorization)\s*:\s*)[^\r\n]+"#)
    private static let sensitiveKeyValueRegex = Self.makeRegex(
        pattern: #"(?i)([\"']?(?:x-api-key|api[-_]?key|access[-_]?token|refresh[-_]?token|"# +
            #"client[-_]?secret|session[-_]?token|password|passwd|secret|token|"# +
            #"aws[-_]?access[-_]?key[-_]?id|aws[-_]?secret[-_]?access[-_]?key)"# +
            #"[\"']?\s*(?::|=)\s*)(?!<redacted)(?:\"[^\"\r\n]*\"|'[^'\r\n]*'|[^\s,;&}\r\n]+)"#)
    private static let bearerRegex = Self.makeRegex(
        pattern: #"(?i)\bbearer\s+[a-z0-9._\-]+=*\b"#)
    private static let minimaxCodingPlanTokenRegex = Self.makeRegex(
        pattern: #"sk-cp-[^\s"'`;,)>\]]+"#)
    private static let minimaxApiTokenRegex = Self.makeRegex(
        pattern: #"sk-api-[^\s"'`;,)>\]]+"#)

    private static let opaqueSecretRegex = Self.makeRegex(
        pattern: #"(?i)\b(?:sk-[a-z0-9][a-z0-9._-]{7,}|github_pat_[a-z0-9_]{10,}|"# +
            #"gh[pousr]_[a-z0-9]{10,}|xox[baprs]-[a-z0-9-]{10,})\b"#)
    private static let awsAccessKeyRegex = Self.makeRegex(
        pattern: #"\b(?:AKIA|ASIA|AIDA|AROA|AIPA|ANPA|ANVA|ASCA)[A-Z0-9]{16}\b"#)

    public static func redact(_ text: String) -> String {
        guard self.mayContainSensitiveValue(text) else { return text }

        var output = text
        // Email is broad and safe first
        output = self.replace(self.emailRegex, in: output, with: "<redacted-email>")
        // MiniMax tokens before broader rules catch them
        output = self.replace(self.minimaxCodingPlanTokenRegex, in: output, with: "<redacted-minimax-token>")
        output = self.replace(self.minimaxApiTokenRegex, in: output, with: "<redacted-minimax-token>")
        output = self.replace(self.opaqueSecretRegex, in: output, with: "<redacted-secret>")
        output = self.replace(self.awsAccessKeyRegex, in: output, with: "<redacted-aws-access-key>")
        // Bearer catches "bearer <token>" before authorization wraps it
        output = self.replace(self.bearerRegex, in: output, with: "Bearer <redacted>")
        // Authorization catches the rest (already-redacted content)
        #if os(macOS)
        output = self.replace(self.cookieDiagnosticRegex, in: output, with: "$1<redacted>")
        #endif
        output = self.replace(self.cookieHeaderRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.authorizationRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.sensitiveHeaderRegex, in: output, with: "$1<redacted>")
        output = self.replace(self.sensitiveKeyValueRegex, in: output, with: "$1<redacted>")
        return output
    }

    private static func mayContainSensitiveValue(_ text: String) -> Bool {
        if text.range(of: "@") != nil { return true }
        if text.range(of: "sk-cp-", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "sk-api-", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "bearer", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "cookie", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "authorization", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "key", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "token", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "secret", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "password", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "passwd", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "sk-", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "github_pat_", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "gh", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "xox", options: [.caseInsensitive]) != nil { return true }
        if text.range(of: "AIDA") != nil || text.range(of: "AIPA") != nil { return true }
        if text.range(of: "AKIA") != nil || text.range(of: "ANPA") != nil { return true }
        if text.range(of: "ANVA") != nil || text.range(of: "AROA") != nil { return true }
        if text.range(of: "ASCA") != nil || text.range(of: "ASIA") != nil { return true }
        return false
    }

    private static func makeRegex(pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        (try? NSRegularExpression(pattern: pattern, options: options)) ?? self.fallbackRegex
    }

    private static func replace(_ regex: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
