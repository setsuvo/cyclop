import AppKit
import Darwin
import UniformTypeIdentifiers

/// Watches the folder `screencapture` writes file-based screenshots into —
/// ⌘⇧3/⌘⇧4 without holding Ctrl, which save straight to disk and never touch
/// the pasteboard, so `ClipboardStore` never sees them (#18).
///
/// Off by default and never watches on its own: since Catalina, macOS gates
/// programmatic access to Desktop/Documents/Downloads behind a Privacy
/// prompt for every app, sandboxed or not — the one exception is a folder
/// the user hands over through a standard Open panel, which counts as
/// consent on its own and asks nothing further. `requestAccess` is that
/// panel; nothing here reads the folder before it has been called once and
/// approved.
@MainActor
final class ScreenshotFolderWatcher {
    /// A new screenshot file, ready to go on the shelf.
    var onImage: ((URL) -> Void)?

    private let enabledKey = "screenshotFolderWatch.enabled"
    private let pathKey = "screenshotFolderWatch.path"
    private let defaults: UserDefaults

    private var source: DispatchSourceFileSystemObject?
    /// Invalidates delayed stability checks when the watch is disabled.
    private var generation = 0
    /// Names already accounted for — either seen at watch-start or already
    /// handed to `onImage`. Keeps a rename or a second write to the same
    /// name from being reported twice.
    private var seen: Set<String> = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        defaults.bool(forKey: enabledKey)
    }

    var folderPath: String? {
        defaults.string(forKey: pathKey)
    }

    var isWatching: Bool { source != nil }

    /// Where `screencapture` saves files today — read the same preference it
    /// does, so the picker opens on the folder that actually fills up.
    static var systemLocation: URL {
        if let path = UserDefaults(suiteName: "com.apple.screencapture")?.string(forKey: "location"),
           !path.isEmpty {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
    }

    /// Puts up the Open panel that stands in for a Privacy prompt. Starts
    /// watching immediately on approval; changes nothing on cancel.
    func requestAccess(
        startWatching: @escaping @MainActor () -> Bool,
        completion: @escaping (Bool) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = localized("Choose Screenshots Folder")
        panel.message = localized(
            "Cyclop will watch this folder for new screenshots and add them to the shelf."
        )
        panel.prompt = localized("Watch")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = Self.systemLocation
        panel.begin { [weak self] response in
            guard let self, response == .OK, let url = panel.url else {
                completion(false)
                return
            }
            // Visibility can change while the Open panel is up, so evaluate
            // this after approval rather than when the switch was clicked.
            self.rememberAccess(to: url, startWatching: startWatching())
            completion(true)
        }
    }

    /// Records the user's folder grant separately from arming the collector.
    /// A hidden Shelf may keep the grant for later, but must stay idle now.
    func rememberAccess(to url: URL, startWatching: Bool) {
        defaults.set(url.path, forKey: pathKey)
        defaults.set(true, forKey: enabledKey)
        if startWatching {
            start(at: url)
        } else {
            stop()
        }
    }

    /// Called at launch. Silent — the folder was already granted once, so
    /// resuming asks nothing further.
    func resumeIfEnabled() {
        guard isEnabled, let folderPath else { return }
        start(at: URL(fileURLWithPath: folderPath, isDirectory: true))
    }

    /// The Settings tab's off switch. Clears the grant along with the watch, so
    /// turning it back on goes through the panel again rather than silently
    /// resuming access nobody remembers giving.
    func disable() {
        defaults.set(false, forKey: enabledKey)
        defaults.removeObject(forKey: pathKey)
        stop()
    }

    func stop() {
        generation &+= 1
        source?.cancel()
        source = nil
    }

    private func start(at folder: URL) {
        stop()
        let generation = self.generation
        // A remembered path can be replaced between launches. Do not follow a
        // directory symlink into a location the user never approved.
        let fd = Darwin.open(folder.path, O_EVTONLY | O_NOFOLLOW)
        guard fd >= 0 else { return }
        var status = stat()
        guard Darwin.fstat(fd, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR else {
            Darwin.close(fd)
            return
        }
        seen = Set(entries(in: folder).map(\.lastPathComponent))

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main
        )
        // Очередь здесь — главная, и это условие работоспособности, а не
        // удобство. Замыкание, записанное внутри `@MainActor`-типа, изоляцию
        // этого типа наследует — у `setEventHandler` параметр не помечен
        // `@Sendable`, проверено компилятором, — и рантайм сверяет её при
        // каждом вызове. С фоновой очередью проверка не прошла бы, и процесс
        // снимался бы на первом же изменении папки. Менять `queue` без
        // `@Sendable` на обоих обработчиках нельзя.
        source.setEventHandler { [weak self] in self?.scan(folder, generation: generation) }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    /// A directory `.write` event fires for any change to its listing — new
    /// file, rename, delete — so this diffs against `seen` rather than
    /// trusting the event to mean "a screenshot arrived".
    private func scan(_ folder: URL, generation: Int) {
        guard generation == self.generation else { return }
        for url in entries(in: folder) {
            let name = url.lastPathComponent
            guard !seen.contains(name) else { continue }
            seen.insert(name)
            guard let type = UTType(filenameExtension: url.pathExtension),
                  type.conforms(to: .image),
                  Self.isEligibleImage(at: url) else { continue }
            waitForStableSize(url, lastSize: -1, attempt: 0, generation: generation)
        }
    }

    /// `screencapture` writes the file in one shot, but checking twice for a
    /// steady size costs nothing and guards against a half-written file on a
    /// slow volume — the same caution `ClipboardStore.awaitImage` uses for
    /// screenshots arriving over Continuity.
    private func waitForStableSize(_ url: URL, lastSize: Int, attempt: Int, generation: Int) {
        guard generation == self.generation else { return }
        guard Self.isEligibleImage(at: url) else { return }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int else {
            return
        }
        if size == lastSize && size > 0 {
            onImage?(url)
            return
        }
        guard attempt < 10 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.waitForStableSize(
                url,
                lastSize: size,
                attempt: attempt + 1,
                generation: generation
            )
        }
    }

    private func entries(in folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// File extensions are only a hint. Never hand a symlink, directory,
    /// FIFO, or device to Quick Look or the shelf as an incoming screenshot.
    static func isEligibleImage(at url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return false }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }
}
