import Foundation

enum SubprocessEnvironment {
    private static let allowedKeys: Set<String> = [
        "COLORTERM",
        "HOME",
        "LANG",
        "LOGNAME",
        "NODE_EXTRA_CA_CERTS",
        "SHELL",
        "SSL_CERT_DIR",
        "SSL_CERT_FILE",
        "TERM",
        "TMPDIR",
        "TZ",
        "USER",
        "XDG_CACHE_HOME",
        "XDG_CONFIG_HOME",
        "XDG_DATA_HOME",
        "XDG_STATE_HOME",
    ]

    /// Builds a minimal inherited environment for third-party CLIs. Provider
    /// credentials, proxy credentials, dynamic-loader injection variables, and
    /// unrelated application secrets are deliberately omitted.
    static func allowlisted(
        from environment: [String: String],
        adding additional: [String: String] = [:]) -> [String: String]
    {
        var result = environment.filter { key, _ in
            self.allowedKeys.contains(key) || key.hasPrefix("LC_")
        }
        result.merge(additional) { _, replacement in replacement }
        return result
    }
}
