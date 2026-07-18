import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum SecureLocalFileError: LocalizedError {
    case invalidURL
    case insecureDirectory
    case insecureFile
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The local file path is invalid."
        case .insecureDirectory:
            "The local file directory is not a private, owner-controlled directory."
        case .insecureFile:
            "The local file is not a private, owner-controlled regular file."
        case let .posix(operation, code):
            "\(operation) failed: \(String(cString: strerror(code)))"
        }
    }
}

/// POSIX file access for local state that may contain diagnostics or secret references.
/// The final directory and file components are opened without following symbolic links,
/// ownership is restricted to the current user, and writes replace files atomically.
enum SecureLocalFile {
    static func readIfPresent(from url: URL) throws -> Data? {
        guard let location = try self.openParentDirectory(for: url, createIfMissing: false) else {
            return nil
        }
        defer { close(location.descriptor) }

        let descriptor = location.name.withCString {
            openat(location.descriptor, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.posixError("open")
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try self.validateFile(descriptor: descriptor, repairPermissions: true)
            let data = try handle.readToEnd() ?? Data()
            try handle.close()
            return data
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default) throws
    {
        guard let location = try self.openParentDirectory(
            for: url,
            createIfMissing: true,
            fileManager: fileManager)
        else {
            throw SecureLocalFileError.insecureDirectory
        }
        defer { close(location.descriptor) }

        try self.validateExistingTarget(name: location.name, directoryDescriptor: location.descriptor)

        let temporaryName = ".\(location.name).\(UUID().uuidString).tmp"
        let descriptor = temporaryName.withCString {
            openat(
                location.descriptor,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600))
        }
        guard descriptor >= 0 else { throw Self.posixError("open temporary file") }

        var renamed = false
        defer {
            if !renamed {
                temporaryName.withCString { _ = unlinkat(location.descriptor, $0, 0) }
            }
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }

        let renameResult = temporaryName.withCString { temporaryPath in
            location.name.withCString { destinationPath in
                renameat(location.descriptor, temporaryPath, location.descriptor, destinationPath)
            }
        }
        guard renameResult == 0 else { throw Self.posixError("replace local file") }
        renamed = true
        guard fsync(location.descriptor) == 0 else { throw Self.posixError("synchronize local file directory") }
    }

    static func removeIfPresent(at url: URL) throws -> Bool {
        guard let location = try self.openParentDirectory(for: url, createIfMissing: false) else {
            return false
        }
        defer { close(location.descriptor) }

        guard try self.validateExistingTarget(
            name: location.name,
            directoryDescriptor: location.descriptor,
            allowMissing: true)
        else {
            return false
        }
        let result = location.name.withCString { unlinkat(location.descriptor, $0, 0) }
        guard result == 0 else { throw Self.posixError("remove local file") }
        return true
    }

    static func openForAppending(
        to url: URL,
        maximumBytes: Int64,
        fileManager: FileManager = .default) throws -> FileHandle
    {
        guard let location = try self.openParentDirectory(
            for: url,
            createIfMissing: true,
            fileManager: fileManager)
        else {
            throw SecureLocalFileError.insecureDirectory
        }
        defer { close(location.descriptor) }

        try self.validateExistingTarget(name: location.name, directoryDescriptor: location.descriptor)
        let descriptor = location.name.withCString {
            openat(
                location.descriptor,
                $0,
                O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
                mode_t(0o600))
        }
        guard descriptor >= 0 else { throw Self.posixError("open local log") }

        do {
            let info = try self.validateFile(descriptor: descriptor, repairPermissions: true)
            if info.st_size > maximumBytes, ftruncate(descriptor, 0) != 0 {
                throw Self.posixError("truncate local log")
            }
            return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openParentDirectory(
        for url: URL,
        createIfMissing: Bool,
        fileManager: FileManager = .default) throws -> (descriptor: Int32, name: String)?
    {
        guard url.isFileURL else { throw SecureLocalFileError.invalidURL }
        let name = url.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            throw SecureLocalFileError.invalidURL
        }

        let directory = url.deletingLastPathComponent()
        if createIfMissing, !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        }

        let descriptor = directory.path.withCString {
            open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else {
            if !createIfMissing, errno == ENOENT { return nil }
            throw Self.posixError("open local file directory")
        }

        do {
            try self.validateDirectory(descriptor: descriptor)
            return (descriptor, name)
        } catch {
            close(descriptor)
            throw error
        }
    }

    @discardableResult
    private static func validateExistingTarget(
        name: String,
        directoryDescriptor: Int32,
        allowMissing: Bool = false) throws -> Bool
    {
        var info = stat()
        let result = name.withCString {
            fstatat(directoryDescriptor, $0, &info, AT_SYMLINK_NOFOLLOW)
        }
        guard result == 0 else {
            if errno == ENOENT, allowMissing { return false }
            if errno == ENOENT { return true }
            throw Self.posixError("inspect local file")
        }
        guard self.isRegularFile(info.st_mode), info.st_uid == getuid() else {
            throw SecureLocalFileError.insecureFile
        }
        return true
    }

    private static func validateDirectory(descriptor: Int32) throws {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError("inspect local file directory") }
        guard self.isDirectory(info.st_mode), info.st_uid == getuid() else {
            throw SecureLocalFileError.insecureDirectory
        }
        if info.st_mode & mode_t(0o077) != 0, fchmod(descriptor, mode_t(0o700)) != 0 {
            throw Self.posixError("restrict local file directory permissions")
        }
    }

    @discardableResult
    private static func validateFile(descriptor: Int32, repairPermissions: Bool) throws -> stat {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { throw Self.posixError("inspect local file") }
        guard self.isRegularFile(info.st_mode), info.st_uid == getuid() else {
            throw SecureLocalFileError.insecureFile
        }
        if repairPermissions, info.st_mode & mode_t(0o077) != 0 {
            guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                throw Self.posixError("restrict local file permissions")
            }
            info.st_mode = (info.st_mode & ~mode_t(0o777)) | mode_t(0o600)
        }
        return info
    }

    private static func isDirectory(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
    }

    private static func isRegularFile(_ mode: mode_t) -> Bool {
        mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    private static func posixError(_ operation: String) -> SecureLocalFileError {
        .posix(operation: operation, code: errno)
    }
}
