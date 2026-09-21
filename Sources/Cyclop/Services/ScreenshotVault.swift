import AppKit

/// Where clipboard screenshots are kept.
///
/// A screenshot taken to the clipboard exists only in memory: paste it once and
/// it is gone. The vault writes it to disk so the shelf can hold on to it.
/// Nothing here is ever deleted automatically — the folder is the user's.
enum ScreenshotVault {
    static let maxFileBytes = 25 * 1_024 * 1_024
    static let maxFiles = 200
    static let maxTotalBytes: Int64 = 512 * 1_024 * 1_024

    private static let picturesFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Pictures", isDirectory: true)
        .appendingPathComponent("Cyclop", isDirectory: true)

    private static var supportFolder: URL {
        Support.folder.appendingPathComponent("Screenshots", isDirectory: true)
    }

    /// `~/Pictures/Cyclop` when it can be created — it is findable, and unlike
    /// Desktop or Documents it is not behind a TCC prompt. Falls back to the
    /// app's own support folder, which always works.
    static let folder: URL = {
        if (try? Support.makePrivateDirectory(at: picturesFolder)) != nil {
            return picturesFolder
        }
        return Support.directory("Screenshots")
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = localized("yyyy-MM-dd 'at' HH.mm.ss")
        return formatter
    }()

    /// Upgrades files made by older versions before clipboard-image saving
    /// became owner-only. This runs even when saving is currently disabled:
    /// old screenshots are still sensitive, and waiting for another save can
    /// leave them world-readable indefinitely.
    static func hardenExistingStorage() {
        hardenExistingStorage(at: picturesFolder)
        hardenExistingStorage(at: supportFolder)
    }

    /// Separate entry point keeps the migration testable without touching the
    /// user's Pictures folder. Symlinks are deliberately skipped so a crafted
    /// entry cannot make Cyclop chmod an unrelated file.
    static func hardenExistingStorage(at directory: URL) {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

        do {
            // This also rejects a symlinked immediate parent. Checking only
            // the final component would still follow ~/Pictures -> elsewhere.
            try Support.makePrivateDirectory(at: directory)
            guard let files = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            ) else { return }
            while let file = files.nextObject() as? URL {
                let values = try file.resourceValues(forKeys: keys)
                if values.isDirectory == true {
                    files.skipDescendants()
                    continue
                }
                guard file.pathExtension.lowercased() == "png" else { continue }
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        } catch {
            NSLog("Cyclop: cannot protect existing screenshots: \(error.localizedDescription)")
        }
    }

    static func save(_ png: Data, at date: Date = Date()) -> URL? {
        guard ensureSafeFolder(folder) else { return nil }
        let current = usage()
        guard canSave(byteCount: png.count, usage: current) else {
            NSLog("Cyclop: refusing clipboard image outside the screenshot storage limits")
            return nil
        }
        let base = "\(localized("Screenshot")) \(stamp.string(from: date))"
        var url = folder.appendingPathComponent("\(base).png")
        // Two screenshots inside one second would otherwise collide.
        var attempt = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appendingPathComponent("\(base) (\(attempt)).png")
            attempt += 1
        }
        do {
            try Support.writePrivate(png, to: url)
            return url
        } catch {
            NSLog("Cyclop: failed to save image: \(error.localizedDescription)")
            return nil
        }
    }

    static func reveal() {
        guard ensureSafeFolder(folder) else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
    }

    /// What the folder holds right now — for the menu item that offers to
    /// clear it, so the offer names its price.
    static func usage() -> (files: Int, bytes: Int64) {
        guard ensureSafeFolder(folder) else { return (0, 0) }
        return usage(at: folder)
    }

    static func usage(at directory: URL) -> (files: Int, bytes: Int64) {
        guard ensureSafeFolder(directory) else { return (0, 0) }
        let fm = FileManager.default
        guard let urls = fm.enumerator(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }
        var files = 0
        var bytes: Int64 = 0
        while let url = urls.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
            if values?.isDirectory == true {
                urls.skipDescendants()
            }
            files += 1
            guard files <= maxFiles else { return (maxFiles, maxTotalBytes) }
            let size = Int64(values?.fileSize ?? 0)
            guard size >= 0, size <= maxTotalBytes - bytes else {
                return (files, maxTotalBytes)
            }
            bytes += size
        }
        return (files, bytes)
    }

    /// Refuses new data rather than silently deleting old images. Subtraction
    /// avoids overflowing if a damaged filesystem reports an absurd byte count.
    static func canSave(byteCount: Int, usage: (files: Int, bytes: Int64)) -> Bool {
        guard byteCount > 0, byteCount <= maxFileBytes,
              usage.files < maxFiles,
              usage.bytes >= 0,
              usage.bytes <= maxTotalBytes else { return false }
        return Int64(byteCount) <= maxTotalBytes - usage.bytes
    }

    /// To the Trash, not gone. The folder's promise is that nothing in it is
    /// ever deleted behind the user's back; the menu item is the user's own
    /// hand, and the Trash keeps even that reversible.
    static func clear() {
        clear(at: folder)
    }

    static func clear(at directory: URL) {
        guard ensureSafeFolder(directory) else { return }
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }
        for url in urls {
            try? fm.trashItem(at: url, resultingItemURL: nil)
        }
    }

    private static func ensureSafeFolder(_ directory: URL) -> Bool {
        do {
            try Support.makePrivateDirectory(at: directory)
            return true
        } catch {
            NSLog("Cyclop: refusing unsafe screenshot folder: \(error.localizedDescription)")
            return false
        }
    }
}
