import Foundation

public enum AppIdentity {
    public static let displayName = "AgentBar"
    public static let bundleIdentifier = "com.yoyodyne.AgentBar"
    public static let debugBundleIdentifier = "com.yoyodyne.AgentBar.debug"
    public static let teamID = "FSJ87X623Z"
    public static let logSubsystem = bundleIdentifier
    public static let keychainCacheService = "com.yoyodyne.AgentBar.cache"
    public static let configSecretService = "com.yoyodyne.AgentBar.ConfigSecrets.v1"
    public static let configSecretLabel = "AgentBar provider credential"
}
