import Foundation
import Darwin

/// `~/Library/Application Support/Cyclop` — where everything Cyclop keeps of
/// its own lives.
///
/// One place for the path, because four stores were each spelling out the same
/// three lines: find the support directory, append the app's name, make sure it
/// exists. Identical every time, and the kind of thing that stays identical
/// only until one copy is edited and the others are not.
enum Support {
    private enum PrivateStorageError: Error {
        case unsafeDirectory(URL)
        case unsafeFile(URL)
        case invalidReadLimit
        case fileTooLarge(URL)
    }

    /// The folder itself, created on first use. Repeated calls are cheap —
    /// `createDirectory` with `withIntermediateDirectories` is content to find
    /// the folder already there.
    static let folder: URL = {
        let fm = FileManager.default
        let url = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cyclop", isDirectory: true)
        try? makePrivateDirectory(at: url)
        return url
    }()

    /// A file inside it, with the folder guaranteed to exist by the time the
    /// path is handed back — which is the only reason this is a function and
    /// not string concatenation at the call site.
    static func file(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name)
        protectFileIfPresent(at: url)
        return url
    }

    /// A subfolder inside it, created the same way.
    static func directory(_ name: String) -> URL {
        let url = folder.appendingPathComponent(name, isDirectory: true)
        try? makePrivateDirectory(at: url)
        return url
    }

    /// Sensitive local state is deliberately plain text so it can be recovered
    /// and, where documented, edited by hand. The filesystem boundary is still
    /// useful on a shared Mac: only the owning account may traverse its folders
    /// or read its files.
    static func makePrivateDirectory(at url: URL) throws {
        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        if parent.path != url.path, fm.fileExists(atPath: parent.path) {
            let parentValues = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard parentValues.isDirectory == true, parentValues.isSymbolicLink != true else {
                throw PrivateStorageError.unsafeDirectory(parent)
            }
        }
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PrivateStorageError.unsafeDirectory(url)
            }
        } else {
            try fm.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // Check again after creation. This closes the ordinary symlink
            // case and narrows the remaining race to another process running
            // as this same user between these two filesystem operations.
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else {
                throw PrivateStorageError.unsafeDirectory(url)
            }
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    /// Tightens files created by an older build without changing their bytes.
    static func protectFileIfPresent(at url: URL) {
        do {
            try protectFileIfPresentOrThrow(at: url)
        } catch {
            NSLog("Cyclop: cannot protect \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Throwing form for callers that must fail closed before reading. A
    /// best-effort chmod is not enough there: logging a symlink and then
    /// following it with `Data(contentsOf:)` would undo the protection.
    @discardableResult
    static func protectFileIfPresentOrThrow(at url: URL) throws -> Bool {
        let fm = FileManager.default
        try makePrivateDirectory(at: url.deletingLastPathComponent())
        guard !isSymbolicLink(at: url) else { throw PrivateStorageError.unsafeFile(url) }
        guard fm.fileExists(atPath: url.path) else { return false }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { throw PrivateStorageError.unsafeFile(url) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return true
    }

    /// Opens sensitive app state without following its final component and
    /// never allocates beyond the caller's declared limit. The descriptor is
    /// checked after opening, so a FIFO/device cannot block a MainActor store
    /// and a stat/read replacement race cannot change what kind of object is
    /// being read. Re-validating the parent here matters because `Support.file`
    /// is often evaluated once, long before a later reload.
    static func readPrivate(_ url: URL, maxBytes: Int) throws -> Data {
        guard maxBytes > 0, maxBytes < Int.max else {
            throw PrivateStorageError.invalidReadLimit
        }
        try makePrivateDirectory(at: url.deletingLastPathComponent())

        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }

        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG else {
            throw PrivateStorageError.unsafeFile(url)
        }
        guard status.st_size >= 0, status.st_size <= maxBytes else {
            throw PrivateStorageError.fileTooLarge(url)
        }
        guard Darwin.fchmod(descriptor, 0o600) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }

        var data = Data()
        data.reserveCapacity(min(Int(status.st_size), maxBytes))
        while data.count <= maxBytes {
            let remaining = maxBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                  !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw PrivateStorageError.fileTooLarge(url)
    }

    static func isMissingFileError(_ error: Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }

    /// Atomic writes can replace the inode and therefore its mode. Apply 0600
    /// after every replacement instead of relying on the process umask.
    static func writePrivate(_ data: Data, to url: URL) throws {
        try makePrivateDirectory(at: url.deletingLastPathComponent())
        guard !isSymbolicLink(at: url) else { throw PrivateStorageError.unsafeFile(url) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func writePrivate(_ data: Data, to url: URL, maxBytes: Int) throws {
        guard maxBytes > 0, data.count <= maxBytes else {
            throw PrivateStorageError.fileTooLarge(url)
        }
        try writePrivate(data, to: url)
    }

    static func writePrivate(_ string: String, to url: URL) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writePrivate(data, to: url)
    }

    static func writePrivate(_ string: String, to url: URL, maxBytes: Int) throws {
        guard let data = string.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        try writePrivate(data, to: url, maxBytes: maxBytes)
    }

    private static func isSymbolicLink(at url: URL) -> Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }
}
