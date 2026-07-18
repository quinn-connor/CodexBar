import Foundation

public struct AmpCLIProbe: Sendable {
    private static let commandTimeout: TimeInterval = 15
    private let arguments: [String]

    public init() {
        self.arguments = ["usage"]
    }

    init(arguments: [String]) {
        self.arguments = arguments
    }

    public func fetch(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date()) async throws -> AmpUsageSnapshot
    {
        let loginPATH = LoginShellPathCache.shared.current
        guard let executable = BinaryLocator.resolveAmpBinary(env: environment, loginPATH: loginPATH) else {
            throw SubprocessRunnerError.binaryNotFound("amp")
        }

        let commandEnvironment = Self.commandEnvironment(
            environment: environment,
            loginPATH: loginPATH)

        let result = try await SubprocessRunner.run(
            binary: executable,
            arguments: self.arguments,
            environment: commandEnvironment,
            timeout: Self.commandTimeout,
            standardInput: FileHandle.nullDevice,
            label: "amp-usage")
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? result.stderr
            : result.stdout
        guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AmpUsageError.parseFailed("The Amp CLI returned no usage data.")
        }
        return try AmpUsageParser.parse(displayText: output, now: now)
    }

    static func commandEnvironment(
        environment: [String: String],
        loginPATH: [String]?) -> [String: String]
    {
        SubprocessEnvironment.allowlisted(from: environment, adding: [
            "NO_COLOR": "1",
            "PATH": PathBuilder.effectivePATH(
                purposes: [.tty, .nodeTooling],
                env: environment,
                loginPATH: loginPATH),
        ])
    }
}
