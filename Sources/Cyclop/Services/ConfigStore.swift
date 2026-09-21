import AppKit

/// Everything about Cyclop that makes sense on somebody else's Mac, in one
/// file next to `snippets.json` and `notes.json` (#67).
///
/// Before this, the same handful of settings each kept their own place and
/// their own copy of "and what if the key isn't there yet": `showOnAllDisplays`
/// in `NotchGeometry`, `saveClipboardImages` in `NotchViewModel`, the privacy
/// sections in `PrivacyMode`, the teleprompter's speed and font size in
/// `TeleprompterStore`, and, freshest, the tab switches from #80. Harmless at
/// four; every new setting was the fifth spelling of the same question.
///
/// **What comes here.** What has meaning on another Mac. Shelf paths (content,
/// not configuration) and calendar overrides (tied to calendar identifiers on
/// this particular Mac) stay in `UserDefaults` — see #67 for the rule.
///
/// **Migration.** No file yet → built once from the old `UserDefaults` keys
/// and written. The old keys are then left alone: rolling back to a build
/// before this one loses a few switches rather than this app carrying two
/// sources of truth for one release (decided in #67).
@MainActor
final class ConfigStore: ObservableObject {
    private enum ValidationError: Error {
        case unknownPrivacySection
        case nullSecuritySetting
    }

    private struct Teleprompter: Codable, Equatable {
        var speed: Double = 1
        var fontSize: Double = 30
    }

    private struct File: Codable, Equatable {
        var showOnAllDisplays = true
        var saveClipboardImages = false
        /// Absence means the value came from a build where persistence was on
        /// by default rather than from informed consent.
        var clipboardImageConsentVersion = 1
        var privacy: [String] = []
        /// Makes the old exact-four "All" expansion a one-time migration;
        /// without a marker, choosing those same four tabs today would be
        /// silently expanded again at every launch.
        var privacyCoverageVersion = 1
        var teleprompter = Teleprompter()
        var hiddenTabs: [String] = []
        var fullSizeDrawnNotch = false

        init() {}

        /// Every key optional, falling back to the default above. The
        /// synthesized decoder treats a key it does not find as a broken
        /// file, so the first setting added after release would have turned
        /// every existing `config.json` read-only in one go — the file written
        /// by the previous version simply does not have it.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = File()
            // Missing keys are expected when an older build wrote the file.
            // An explicit null is different: treating it as the legacy
            // default could turn a malformed security setting into an opt-in.
            if c.contains(.showOnAllDisplays) {
                guard try !c.decodeNil(forKey: .showOnAllDisplays) else {
                    throw ValidationError.nullSecuritySetting
                }
                showOnAllDisplays = try c.decode(Bool.self, forKey: .showOnAllDisplays)
            } else {
                showOnAllDisplays = d.showOnAllDisplays
            }
            saveClipboardImages = try c.decodeIfPresent(Bool.self, forKey: .saveClipboardImages) ?? d.saveClipboardImages
            clipboardImageConsentVersion = try c.decodeIfPresent(
                Int.self, forKey: .clipboardImageConsentVersion
            ) ?? 0
            // An existing file with no privacy key (or an explicit null) came
            // from an older/incomplete schema. Treat that ambiguity as
            // covered; an explicit empty array is still the user's opt-out.
            if let decodedPrivacy = try c.decodeIfPresent([String].self, forKey: .privacy) {
                privacy = decodedPrivacy
            } else {
                // Kept literal here because Codable invokes this initializer
                // outside the enclosing @MainActor type's isolation.
                privacy = [
                    "media", "shelf", "clipboard", "snippets", "calendar",
                    "translate", "currency", "notes", "teleprompter",
                ]
            }
            privacyCoverageVersion = try c.decodeIfPresent(
                Int.self, forKey: .privacyCoverageVersion
            ) ?? 0
            teleprompter = try c.decodeIfPresent(Teleprompter.self, forKey: .teleprompter) ?? d.teleprompter
            if c.contains(.hiddenTabs) {
                guard try !c.decodeNil(forKey: .hiddenTabs) else {
                    throw ValidationError.nullSecuritySetting
                }
                hiddenTabs = try c.decode([String].self, forKey: .hiddenTabs)
            } else {
                hiddenTabs = d.hiddenTabs
            }
            fullSizeDrawnNotch = try c.decodeIfPresent(Bool.self, forKey: .fullSizeDrawnNotch) ?? d.fullSizeDrawnNotch
        }
    }

    static let shared = ConfigStore()

    /// `~/Library/Application Support/Cyclop/config.json`.
    static let file = Support.file("config.json")

    /// Kept independent of `PrivacyMode.Section` so configuration remains a
    /// storage concern, but deliberately exhaustive. An unreadable file must
    /// hide data before any UI model has been constructed.
    private static let allPrivacySections = [
        "media", "shelf", "clipboard", "snippets", "calendar",
        "translate", "currency", "notes", "teleprompter",
    ]
    private static let legacyAllPrivacySections: Set<String> = [
        "clipboard", "snippets", "calendar", "notes",
    ]
    /// Content-tab raw values are currently identical to privacy-section raw
    /// values. Settings is deliberately absent: it must remain reachable to
    /// repair a broken configuration.
    private static let allHiddenTabs = allPrivacySections
    /// Small fail-safe records in a separate preferences domain bridge the
    /// rare case where config.json cannot be replaced (disk full, permissions,
    /// interrupted atomic write). They are removed only after the same safe
    /// state has reached config.json.
    private static let clipboardForcedOffKey = "security.clipboardImagesForcedOff"
    private static let privacyFallbackKey = "security.privacySectionsFallback"
    private static let hiddenTabsFallbackKey = "security.hiddenTabsFallback"
    private static let allDisplaysForcedOffKey = "security.allDisplaysForcedOff"

    /// True when the file exists but cannot be parsed — same meaning and the
    /// same consequence as `SnippetStore.fileBroken` (#7): reading stays
    /// honest, and writing stops rather than paving over a hand edit gone
    /// wrong.
    @Published private(set) var fileBroken = false
    /// A syntactically valid file can still become unwritable later. Surface
    /// that instead of letting a switch look durable when it is not.
    @Published private(set) var writeFailed = false

    private var value: File
    private let storageURL: URL
    private let preferences: UserDefaults
    private let dataWriter: (Data, URL) throws -> Void

    init(
        fileURL: URL = ConfigStore.file,
        defaults: UserDefaults = .standard,
        readData: (URL) throws -> Data = { try Support.readPrivate($0, maxBytes: 1 * 1_024 * 1_024) },
        writeData: @escaping (Data, URL) throws -> Void = { data, url in
            try Support.writePrivate(data, to: url)
        }
    ) {
        storageURL = fileURL
        preferences = defaults
        dataWriter = writeData
        do {
            // Refuse an unsafe/unusable storage parent before deciding that a
            // read failure means "first launch". Otherwise an inaccessible
            // old config could be mistaken for no config and expose panes.
            try Support.makePrivateDirectory(at: fileURL.deletingLastPathComponent())
        } catch {
            value = Self.failClosedFile()
            fileBroken = true
            NSLog("Cyclop: config directory is not usable: \(error.localizedDescription)")
            return
        }

        do {
            // Validate and tighten the final component before opening it. The
            // non-throwing helper is suitable for migrations, not for a
            // security-setting file where a symlink must stop the read.
            try Support.protectFileIfPresentOrThrow(at: fileURL)
            let data = try readData(fileURL)
            var decoded = try JSONDecoder().decode(File.self, from: data)
            guard Set(decoded.privacy).isSubset(of: Set(Self.allPrivacySections)) else {
                throw ValidationError.unknownPrivacySection
            }
            guard Set(decoded.hiddenTabs).isSubset(of: Set(Self.allHiddenTabs)) else {
                throw ValidationError.unknownPrivacySection
            }
            let needsPrivacyMigration = decoded.privacyCoverageVersion < 1
            let needsClipboardConsent = decoded.clipboardImageConsentVersion < 1
            if needsPrivacyMigration {
                decoded.privacy = Self.expandedPrivacy(decoded.privacy)
                decoded.privacyCoverageVersion = 1
            }
            if needsClipboardConsent {
                decoded.saveClipboardImages = false
                decoded.clipboardImageConsentVersion = 1
            }
            let beforeFallbacks = decoded
            decoded = Self.applyingSafetyFallbacks(to: decoded, defaults: defaults)
            let needsFallbackRepair = decoded != beforeFallbacks
            value = decoded
            if needsPrivacyMigration || needsClipboardConsent || needsFallbackRepair {
                write(decoded)
            } else {
                // The durable file already contains the fail-safe state.
                clearSafetyFallbacks()
            }
        } catch {
            if Self.isMissingFileError(error) {
                // A definite ENOENT is the only first-run case. Assemble the
                // old preferences and make that decision durable immediately.
                value = Self.migrated(defaults: defaults)
                value = Self.applyingSafetyFallbacks(to: value, defaults: defaults)
                if !write(value) {
                    // With nowhere trustworthy to remember settings, the
                    // current and next launches must cover everything and
                    // stop every background content source.
                    value = Self.failClosedFile()
                    preferences.set(true, forKey: Self.clipboardForcedOffKey)
                    preferences.set(Self.allPrivacySections, forKey: Self.privacyFallbackKey)
                    preferences.set(Self.allHiddenTabs, forKey: Self.hiddenTabsFallbackKey)
                    preferences.set(true, forKey: Self.allDisplaysForcedOffKey)
                    _ = preferences.synchronize()
                }
            } else {
                value = Self.failClosedFile()
                fileBroken = true
                NSLog("Cyclop: config.json is not readable: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Settings

    /// Persisted switch for every display past the first. Defaults to on: the
    /// panel is meant to be wherever the pointer is, so this is the way to
    /// pull it back to one screen, not the way to ask for the rest.
    var showOnAllDisplays: Bool {
        get { value.showOnAllDisplays }
        set {
            guard !fileBroken else { return }
            if newValue {
                var candidate = value
                candidate.showOnAllDisplays = true
                if write(candidate) { value = candidate }
            } else {
                preferences.set(true, forKey: Self.allDisplaysForcedOffKey)
                _ = preferences.synchronize()
                value.showOnAllDisplays = false
                persist()
            }
        }
    }

    /// Brings back the notch drawn the full height of the menu bar on displays
    /// without a cutout. Off by default: see `NotchGeometry.collapsedDepth`.
    var fullSizeDrawnNotch: Bool {
        get { value.fullSizeDrawnNotch }
        set { guard !fileBroken else { return }; value.fullSizeDrawnNotch = newValue; persist() }
    }

    /// Explicit opt-in for persisting clipboard images. Plain clipboard text
    /// remains memory-only; copied images must not become files by surprise.
    var saveClipboardImages: Bool {
        get { value.saveClipboardImages }
        set {
            guard !fileBroken else { return }
            if newValue {
                // Opting in takes effect only after it is durable. A failed
                // write must never leave this process capturing images while
                // the switch cannot survive a restart honestly.
                var candidate = value
                candidate.saveClipboardImages = true
                candidate.clipboardImageConsentVersion = 1
                if write(candidate) { value = candidate }
            } else {
                // Record the fail-safe before touching config.json. If that
                // write fails, the next launch still forces capture off.
                preferences.set(true, forKey: Self.clipboardForcedOffKey)
                _ = preferences.synchronize()
                value.saveClipboardImages = false
                value.clipboardImageConsentVersion = 1
                persist()
            }
        }
    }

    /// Raw `PrivacyMode.Section` values. Kept as strings here rather than that
    /// type so this store does not need to know about it — the same reason
    /// `hiddenTabs` below is `[String]` and not `[NotchViewModel.Tab]`.
    var privacy: [String] {
        get { value.privacy }
        set {
            guard !fileBroken else { return }
            let old = Set(value.privacy)
            let new = Set(newValue)
            guard new.isSubset(of: Set(Self.allPrivacySections)) else { return }
            let added = new.subtracting(old)
            let removed = old.subtracting(new)
            if !added.isEmpty {
                // Enabling a cover is security-increasing. Mirror the union
                // first so a failed config write cannot expose it next launch.
                preferences.set(Array(old.union(new)).sorted(), forKey: Self.privacyFallbackKey)
                _ = preferences.synchronize()
            }
            if !removed.isEmpty {
                // Uncover only after the less-private state is durable. If a
                // mixed update also added covers, keep those additions in this
                // process even when the exact write fails.
                var candidate = value
                candidate.privacy = newValue
                if write(candidate) {
                    value = candidate
                } else if !added.isEmpty {
                    value.privacy = Array(old.union(added)).sorted()
                }
            } else {
                value.privacy = newValue
                persist()
            }
        }
    }

    var teleprompterSpeed: Double {
        get { value.teleprompter.speed }
        set { guard !fileBroken else { return }; value.teleprompter.speed = newValue; persist() }
    }

    var teleprompterFontSize: Double {
        get { value.teleprompter.fontSize }
        set { guard !fileBroken else { return }; value.teleprompter.fontSize = newValue; persist() }
    }

    /// Tabs switched off in Settings (#80), by `Tab.rawValue`. Kept as the set
    /// of what is off rather than what is on, so a tab added in a later
    /// version shows up for everyone instead of arriving hidden.
    var hiddenTabs: [String] {
        get { value.hiddenTabs }
        set {
            guard !fileBroken else { return }
            let old = Set(value.hiddenTabs)
            let new = Set(newValue)
            guard new.isSubset(of: Set(Self.allHiddenTabs)) else { return }
            let added = new.subtracting(old)
            let removed = old.subtracting(new)
            if !added.isEmpty {
                preferences.set(Array(old.union(new)).sorted(), forKey: Self.hiddenTabsFallbackKey)
                _ = preferences.synchronize()
            }
            if !removed.isEmpty {
                // Re-enabling a hidden tab can restart clipboard, media,
                // calendar or network collection. Apply that only after the
                // less-private state is durably recorded. If the same update
                // hides other tabs, retain those additions on write failure.
                var candidate = value
                candidate.hiddenTabs = newValue
                if write(candidate) {
                    value = candidate
                } else if !added.isEmpty {
                    value.hiddenTabs = Array(old.union(added)).sorted()
                }
            } else {
                value.hiddenTabs = newValue
                persist()
            }
        }
    }

    // MARK: - Migration

    /// Reads the places these settings used to live. Existing choices are kept
    /// except clipboard-image persistence: its legacy value cannot distinguish
    /// an explicit choice from the old default-on behavior, so it is reset and
    /// must be consented to once under the new format.
    private static func migrated(defaults: UserDefaults) -> File {
        var file = File()
        if defaults.object(forKey: "showOnAllDisplays") != nil {
            file.showOnAllDisplays = defaults.bool(forKey: "showOnAllDisplays")
        }
        // The legacy value cannot distinguish an explicit choice from the old
        // default-on behavior. Do not migrate it: this version asks for consent
        // once and records that choice in `clipboardImageConsentVersion`.
        if let storedSections = defaults.object(forKey: "privacyMode.sections") {
            if let sections = storedSections as? [String],
               Set(sections).isSubset(of: Set(allPrivacySections)) {
                file.privacy = expandedPrivacy(sections)
            } else {
                // A present but malformed legacy security preference is not
                // equivalent to the user choosing no covered sections.
                file.privacy = allPrivacySections
            }
        } else if let legacyPrivacy = defaults.object(forKey: "privacyMode") {
            // NSNumber is the property-list representation UserDefaults uses
            // for Bool. A different present type is corruption, not a choice
            // to uncover everything.
            if let number = legacyPrivacy as? NSNumber,
               CFGetTypeID(number) == CFBooleanGetTypeID() {
                if number.boolValue { file.privacy = allPrivacySections }
            } else {
                file.privacy = allPrivacySections
            }
        }
        if let speed = defaults.object(forKey: "teleprompter.speed") as? Double {
            file.teleprompter.speed = speed
        }
        if let fontSize = defaults.object(forKey: "teleprompter.fontSize") as? Double {
            file.teleprompter.fontSize = fontSize
        }
        if let storedHidden = defaults.object(forKey: "hiddenTabs") {
            if let hidden = storedHidden as? [String],
               Set(hidden).isSubset(of: Set(allHiddenTabs)) {
                file.hiddenTabs = hidden
            } else {
                // A malformed security-relevant preference must not restart
                // collectors that the user may have disabled.
                file.hiddenTabs = allHiddenTabs
            }
        }
        return file
    }

    private static func failClosedFile() -> File {
        var file = File()
        file.showOnAllDisplays = false
        file.saveClipboardImages = false
        file.privacy = allPrivacySections
        file.hiddenTabs = allHiddenTabs
        return file
    }

    /// In v0.8.2 these four values were every section. Preserve the meaning of
    /// that exact set when newer tabs gain privacy coverage.
    private static func expandedPrivacy(_ values: [String]) -> [String] {
        Set(values) == legacyAllPrivacySections ? allPrivacySections : values
    }

    private static func applyingSafetyFallbacks(to source: File, defaults: UserDefaults) -> File {
        var file = source
        if defaults.bool(forKey: clipboardForcedOffKey) {
            file.saveClipboardImages = false
            file.clipboardImageConsentVersion = 1
        }
        if let stored = defaults.object(forKey: privacyFallbackKey) {
            if let raw = stored as? [String], Set(raw).isSubset(of: Set(allPrivacySections)) {
                file.privacy = Array(Set(file.privacy).union(raw)).sorted()
            } else {
                file.privacy = allPrivacySections
            }
        }
        if let stored = defaults.object(forKey: hiddenTabsFallbackKey) {
            if let hidden = stored as? [String], Set(hidden).isSubset(of: Set(allHiddenTabs)) {
                file.hiddenTabs = Array(Set(file.hiddenTabs).union(hidden)).sorted()
            } else {
                file.hiddenTabs = allHiddenTabs
            }
        }
        if defaults.bool(forKey: allDisplaysForcedOffKey) {
            file.showOnAllDisplays = false
        }
        return file
    }

    private static func isMissingFileError(_ error: Error) -> Bool {
        Support.isMissingFileError(error)
    }

    // MARK: - Storage

    private func persist() {
        write(value)
    }

    /// Pretty-printed, and slashes left alone — same reason as
    /// `snippets.json`: this file is meant to be opened, edited by hand, and
    /// handed to somebody else's Mac.
    @discardableResult
    private func write(_ file: File) -> Bool {
        guard !fileBroken else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        do {
            try dataWriter(encoder.encode(file), storageURL)
            writeFailed = false
            clearSafetyFallbacks()
            return true
        } catch {
            writeFailed = true
            NSLog("Cyclop: cannot write config.json: \(error.localizedDescription)")
            return false
        }
    }

    private func clearSafetyFallbacks() {
        preferences.removeObject(forKey: Self.clipboardForcedOffKey)
        preferences.removeObject(forKey: Self.privacyFallbackKey)
        preferences.removeObject(forKey: Self.hiddenTabsFallbackKey)
        preferences.removeObject(forKey: Self.allDisplaysForcedOffKey)
        _ = preferences.synchronize()
    }

    static func reveal() {
        if !FileManager.default.fileExists(atPath: file.path) {
            shared.write(shared.value)
        }
        NSWorkspace.shared.activateFileViewerSelecting([file])
    }
}
