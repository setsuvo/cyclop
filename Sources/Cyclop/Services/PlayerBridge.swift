import AppKit

/// Public-API bridge to the two scriptable players macOS ships with support
/// for. Everything goes through AppleScript (state, artwork, transport) and
/// distributed notifications (change events) — no private frameworks.
enum PlayerApp: String, CaseIterable {
    case music, spotify

    var bundleID: String {
        switch self {
        case .music: return "com.apple.Music"
        case .spotify: return "com.spotify.client"
        }
    }

    var displayName: String {
        switch self {
        case .music: return "Apple Music"
        case .spotify: return "Spotify"
        }
    }

    /// Distributed notification the player posts on every state change.
    var changeNotification: Notification.Name {
        switch self {
        case .music: return Notification.Name("com.apple.Music.playerInfo")
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
}

struct PlayerState {
    var app: PlayerApp
    var isPlaying: Bool
    var title: String
    var artist: String
    var album: String
    var duration: TimeInterval
    var position: TimeInterval
    var artworkURL: URL?
    /// Identity of the track, used to decide when artwork must be refetched.
    var key: String { "\(app.rawValue)|\(title)|\(artist)|\(album)" }
}

/// Called from the panel and answering to it: every entry point here is
/// reached from `MediaController`, and every completion is delivered back on
/// the main thread. Saying so out loud is what `.v6` asks for — the work still
/// happens on `queue` and in `URLSession`, and only the answer comes home.
@MainActor
enum PlayerBridge {
    private static let queue = DispatchQueue(label: "com.cyclop.applescript", qos: .utility)

    // MARK: - State

    static func state(of app: PlayerApp, completion: @escaping (PlayerState?) -> Void) {
        guard app.isRunning else { return completion(nil) }
        runScript(stateScript(for: app)) { descriptor in
            guard let raw = descriptor?.stringValue, !raw.isEmpty else { return completion(nil) }
            completion(parse(raw, app: app))
        }
    }

    /// Never launches a player: only already-running ones are queried, and a
    /// playing app wins over a merely-open one.
    static func currentState(completion: @escaping (PlayerState?) -> Void) {
        let candidates = PlayerApp.allCases.filter(\.isRunning)
        guard !candidates.isEmpty else { return completion(nil) }

        var results: [PlayerState] = []
        let group = DispatchGroup()
        for app in candidates {
            group.enter()
            state(of: app) { state in
                if let state { results.append(state) }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            completion(results.first(where: \.isPlaying) ?? results.first)
        }
    }

    // MARK: - Transport

    static func playPause(_ app: PlayerApp) { command("playpause", on: app) }
    static func next(_ app: PlayerApp) { command("next track", on: app) }
    static func previous(_ app: PlayerApp) {
        // Spotify's `previous track` restarts the current song first, matching
        // its own UI; Music behaves the same way. Seeking to 0 first is what
        // users expect from a "skip back" button.
        command(app == .spotify ? "set player position to 0\n    previous track" : "back track", on: app)
    }

    static func seek(_ app: PlayerApp, to seconds: TimeInterval) {
        command("set player position to \(Int(seconds))", on: app)
    }

    private static func command(_ body: String, on app: PlayerApp) {
        guard app.isRunning else { return }
        runScript("""
        tell application id "\(app.bundleID)"
            \(body)
        end tell
        """) { _ in }
    }

    /// System-wide media key, used when no scriptable player is running.
    /// Requires Accessibility permission; silently does nothing without it.
    static func postMediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags: Int = down ? 0xA00 : 0xB00
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (Int(key) << 16) | flags,
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    enum MediaKey: Int32 {
        case playPause = 16, next = 17, previous = 18
    }

    // MARK: - Artwork

    @discardableResult
    static func artwork(
        for state: PlayerState,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) -> Task<Void, Never>? {
        switch state.app {
        case .spotify:
            // The address comes out of another app's scripting dictionary and
            // is therefore untrusted input. Only Spotify's artwork endpoint is
            // accepted; the same rule is re-applied after every redirect.
            let destinations = [
                NetworkPolicy.Destination(host: "i.scdn.co", pathPrefix: "/image/"),
            ]
            guard let url = state.artworkURL,
                  destinations.contains(where: { $0.allows(url) }) else {
                completion(nil)
                return nil
            }
            return Task {
                do {
                    let data = try await NetworkPolicy.load(
                        URLRequest(url: url),
                        destinations: destinations,
                        maxBytes: 8 * 1_024 * 1_024,
                        contentTypes: ["image/jpeg", "image/png", "image/webp"]
                    )
                    try Task.checkCancellation()
                    guard ImagePolicy.accepts(
                        data,
                        maxBytes: 8 * 1_024 * 1_024,
                        maxPixels: 20_000_000,
                        maxFrames: 1
                    ) else {
                        return completion(nil)
                    }
                    try Task.checkCancellation()
                    completion(NSImage(data: data))
                } catch is CancellationError {
                    return
                } catch {
                    completion(nil)
                }
            }
        case .music:
            runScript("""
            tell application id "com.apple.Music"
                if (count of artworks of current track) is 0 then return missing value
                return raw data of artwork 1 of current track
            end tell
            """) { descriptor in
                guard let data = descriptor?.data,
                      ImagePolicy.accepts(
                        data,
                        maxBytes: 8 * 1_024 * 1_024,
                        maxPixels: 20_000_000,
                        maxFrames: 1
                      ) else { return completion(nil) }
                completion(NSImage(data: data))
            }
            return nil
        }
    }

    // MARK: - Scripts

    private static func stateScript(for app: PlayerApp) -> String {
        let sep = "set sep to character id 1"
        switch app {
        case .spotify:
            return """
            \(sep)
            tell application id "com.spotify.client"
                try
                    set pstate to player state as text
                    set t to current track
                    try
                        set pos to (round ((player position) * 1000))
                    on error
                        set pos to 0
                    end try
                    return pstate & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (duration of t) & sep & pos & sep & (artwork url of t)
                on error
                    return ""
                end try
            end tell
            """
        case .music:
            return """
            \(sep)
            tell application id "com.apple.Music"
                try
                    set pstate to player state as text
                    set t to current track
                    try
                        set pos to (round ((player position) * 1000))
                    on error
                        set pos to 0
                    end try
                    return pstate & sep & (name of t) & sep & (artist of t) & sep & (album of t) & sep & (round ((duration of t) * 1000)) & sep & pos & sep & ""
                on error
                    return ""
                end try
            end tell
            """
        }
    }

    private static func parse(_ raw: String, app: PlayerApp) -> PlayerState? {
        guard raw.utf8.count <= 32 * 1_024 else { return nil }
        let parts = raw.components(separatedBy: "\u{1}")
        guard parts.count >= 6, !parts[1].isEmpty else { return nil }
        let duration = boundedNumber(parts[4], maximum: 315_576_000)
        let position = boundedNumber(parts[5], maximum: 315_576_000)
        let artwork = parts.count > 6 && parts[6].utf8.count <= 2_048
            ? URL(string: parts[6])
            : nil
        return PlayerState(
            app: app,
            isPlaying: parts[0].lowercased() == "playing",
            title: boundedText(parts[1]),
            artist: boundedText(parts[2]),
            album: boundedText(parts[3]),
            duration: duration / 1_000,
            position: position / 1_000,
            artworkURL: artwork
        )
    }

    private static let unsafeTextControls = CharacterSet(
        charactersIn: "\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}"
    ).union(.controlCharacters)

    private static func boundedText(_ value: String) -> String {
        let scalars = value.unicodeScalars.lazy.filter { !unsafeTextControls.contains($0) }
        return String(String.UnicodeScalarView(scalars.prefix(512)))
    }

    private static func boundedNumber(_ value: String, maximum: Double) -> Double {
        guard let number = Double(value), number.isFinite,
              number >= 0, number <= maximum * 1_000 else { return 0 }
        return number
    }

    /// Shared AppleScript runner: one serial queue for every script the app sends.
    static func runScript(_ source: String, completion: @escaping @MainActor (NSAppleEventDescriptor?) -> Void) {
        queue.async {
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error, let code = error[NSAppleScript.errorNumber] as? Int, code != 0 {
                NSLog("Cyclop: AppleScript error \(code): \(error[NSAppleScript.errorMessage] ?? "")")
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(result) } }
        }
    }
}
