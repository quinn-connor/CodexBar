import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct SecureLocalFileTests {
    @Test
    func `atomic writes create owner-only directories and files`() throws {
        let root = try Self.makeRoot("write")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root
            .appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent("config.json")

        try SecureLocalFile.write(Data("first".utf8), to: url)
        try SecureLocalFile.write(Data("second".utf8), to: url)

        #expect(try SecureLocalFile.readIfPresent(from: url) == Data("second".utf8))
        #expect(try Self.permissions(of: url.deletingLastPathComponent()) == 0o700)
        #expect(try Self.permissions(of: url) == 0o600)
    }

    @Test
    func `append access creates an owner-only log and truncates oversized content`() throws {
        let root = try Self.makeRoot("append")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root
            .appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("AgentBar.log")

        var handle = try SecureLocalFile.openForAppending(to: url, maximumBytes: 5)
        try handle.write(contentsOf: Data("oversized".utf8))
        try handle.close()
        handle = try SecureLocalFile.openForAppending(to: url, maximumBytes: 5)
        try handle.write(contentsOf: Data("safe".utf8))
        try handle.close()

        #expect(try SecureLocalFile.readIfPresent(from: url) == Data("safe".utf8))
        #expect(try Self.permissions(of: url.deletingLastPathComponent()) == 0o700)
        #expect(try Self.permissions(of: url) == 0o600)
    }

    @Test
    func `existing permissive files are restricted before reading`() throws {
        let root = try Self.makeRoot("repair")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("config.json")
        try Data("private".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        #expect(try SecureLocalFile.readIfPresent(from: url) == Data("private".utf8))
        #expect(try Self.permissions(of: directory) == 0o700)
        #expect(try Self.permissions(of: url) == 0o600)
    }

    @Test
    func `symbolic link files are rejected for every operation`() throws {
        let root = try Self.makeRoot("file-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("private", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let target = root.appendingPathComponent("target")
        try Data("do-not-touch".utf8).write(to: target)
        let link = directory.appendingPathComponent("config.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        #expect(throws: SecureLocalFileError.self) {
            _ = try SecureLocalFile.readIfPresent(from: link)
        }
        #expect(throws: SecureLocalFileError.self) {
            try SecureLocalFile.write(Data("replacement".utf8), to: link)
        }
        #expect(throws: SecureLocalFileError.self) {
            _ = try SecureLocalFile.removeIfPresent(at: link)
        }
        #expect(throws: SecureLocalFileError.self) {
            _ = try SecureLocalFile.openForAppending(to: link, maximumBytes: 100)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "do-not-touch")
    }

    @Test
    func `symbolic link directories are rejected`() throws {
        let root = try Self.makeRoot("directory-symlink")
        defer { try? FileManager.default.removeItem(at: root) }
        let targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        let linkedDirectory = root.appendingPathComponent("linked", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedDirectory, withDestinationURL: targetDirectory)
        let url = linkedDirectory.appendingPathComponent("config.json")

        #expect(throws: SecureLocalFileError.self) {
            try SecureLocalFile.write(Data("secret".utf8), to: url)
        }
        #expect(throws: SecureLocalFileError.self) {
            _ = try SecureLocalFile.readIfPresent(from: url)
        }
        #expect(!FileManager.default.fileExists(atPath: targetDirectory.appendingPathComponent("config.json").path))
    }

    @Test
    func `config store uses secure local file permissions`() throws {
        let root = try Self.makeRoot("config-store")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root
            .appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent("config.json")
        let store = CodexBarConfigStore(fileURL: url)

        try store.save(.makeDefault())

        #expect(try Self.permissions(of: url.deletingLastPathComponent()) == 0o700)
        #expect(try Self.permissions(of: url) == 0o600)
        #expect(try store.load() != nil)
    }

    private static func makeRoot(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureLocalFileTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return url
    }

    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        return permissions.intValue & 0o777
    }
}
