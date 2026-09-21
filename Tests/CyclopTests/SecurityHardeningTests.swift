import Foundation
import Testing
@testable import Cyclop

@MainActor
struct SecurityHardeningTests {
    private static func temporaryFile(_ name: String = "config.json") throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyclop-security-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(name)
    }

    @Test func everyContentTabHasAPrivacySection() {
        let contentTabs = NotchViewModel.Tab.allCases.filter { $0 != .settings }
        #expect(contentTabs.allSatisfy { $0.privacySection != nil })
        #expect(Set(contentTabs.compactMap(\.privacySection)) == Set(PrivacyMode.Section.allCases))
        #expect(NotchViewModel.Tab.settings.privacySection == nil)
    }

    @Test func temporaryRevealIsPerDisplayAndResetOnFold() {
        var persisted: [String] = []
        let privacy = PrivacyMode(
            rawSections: PrivacyMode.Section.allCases.map(\.rawValue)
        ) { persisted = $0; return $0 }
        let firstDisplay = UUID()
        let secondDisplay = UUID()

        #expect(privacy.coversAll)
        #expect(persisted.isEmpty)

        privacy.reveal(.media, for: firstDisplay)
        #expect(privacy.isEnabled(.media))
        #expect(!privacy.covers(.media, for: firstDisplay))
        #expect(privacy.covers(.media, for: secondDisplay))
        privacy.coverEverything(for: firstDisplay)
        #expect(privacy.covers(.media, for: firstDisplay))
    }

    @Test func unreadableConfigFailsClosedAndCannotBeUncovered() throws {
        let file = try Self.temporaryFile()
        try Data(#"{"#.utf8).write(to: file)
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ConfigStore(fileURL: file, defaults: defaults)
        #expect(config.fileBroken)
        #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(Set(config.hiddenTabs) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(!config.showOnAllDisplays)
        config.privacy = []
        #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))

        let privacy = PrivacyMode(
            rawSections: config.privacy,
            persist: { config.privacy = $0; return config.privacy },
            changesAllowed: { !config.fileBroken }
        )
        privacy.setCoveringAll(false)
        #expect(privacy.coversAll)
        #expect(try String(contentsOf: file, encoding: .utf8) == "{")
    }

    @Test func unknownPrivacySectionIsTreatedAsBrokenAndFailsClosed() throws {
        let file = try Self.temporaryFile()
        let original = #"{"privacy":["clipbord"],"clipboardImageConsentVersion":1}"#
        try Data(original.utf8).write(to: file)
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ConfigStore(fileURL: file, defaults: defaults)
        #expect(config.fileBroken)
        #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test func unknownHiddenTabStopsAllContentSources() throws {
        let file = try Self.temporaryFile()
        let original = #"{"privacy":[],"privacyCoverageVersion":1,"hiddenTabs":["clipbord"],"clipboardImageConsentVersion":1}"#
        try Data(original.utf8).write(to: file)
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ConfigStore(fileURL: file, defaults: defaults)
        #expect(config.fileBroken)
        #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(Set(config.hiddenTabs) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(try String(contentsOf: file, encoding: .utf8) == original)
    }

    @Test func newConfigDoesNotPersistClipboardImagesByDefault() throws {
        let file = try Self.temporaryFile()
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ConfigStore(fileURL: file, defaults: defaults)
        #expect(!config.saveClipboardImages)
        #expect(config.privacy.isEmpty)
        #expect(!config.fileBroken)
        #expect(!config.writeFailed)
        #expect(FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unavailableConfigReadIsNotMistakenForFirstLaunch() throws {
        let file = try Self.temporaryFile()
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ConfigStore(
            fileURL: file,
            defaults: defaults,
            readData: { _ in throw CocoaError(.fileReadNoPermission) }
        )
        #expect(config.fileBroken)
        #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func failedFirstConfigWriteCoversEverything() throws {
        let file = try Self.temporaryFile()
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let config = ConfigStore(fileURL: file, defaults: defaults, writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        #expect(config.writeFailed)
        #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(Set(config.hiddenTabs) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(!config.showOnAllDisplays)
        #expect(!config.saveClipboardImages)

        // The separate fallback also closes the next launch once storage is
        // usable again.
        let relaunched = ConfigStore(fileURL: file, defaults: defaults)
        #expect(Set(relaunched.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
    }

    @Test func upgradeResetsOldDefaultOnClipboardPersistenceButKeepsNewConsent() throws {
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let oldFile = try Self.temporaryFile("old.json")
        try Support.writePrivate(Data(#"{"saveClipboardImages":true}"#.utf8), to: oldFile)
        let oldConfig = ConfigStore(fileURL: oldFile, defaults: defaults)
        #expect(!oldConfig.saveClipboardImages)

        let optedInFile = try Self.temporaryFile("opted-in.json")
        try Support.writePrivate(
            Data(#"{"saveClipboardImages":true,"clipboardImageConsentVersion":1}"#.utf8),
            to: optedInFile
        )
        let optedInConfig = ConfigStore(fileURL: optedInFile, defaults: defaults)
        #expect(optedInConfig.saveClipboardImages)
    }

    @Test func legacyUserDefaultsCannotSilentlyOptInClipboardPersistence() throws {
        let file = try Self.temporaryFile()
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "saveClipboardImages")

        let config = ConfigStore(fileURL: file, defaults: defaults)
        #expect(!config.saveClipboardImages)
    }

    @Test func malformedLegacyHiddenTabsStopsAllContentSources() throws {
        let malformed: [Any] = [["clipbord"], "clipboard"]
        for stored in malformed {
            let file = try Self.temporaryFile()
            let suite = "cyclop-security-\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.set(stored, forKey: "hiddenTabs")

            let config = ConfigStore(fileURL: file, defaults: defaults)
            #expect(Set(config.hiddenTabs) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        }
    }

    @Test func malformedLegacyPrivacyPreferenceFailsClosedImmediately() throws {
        let file = try Self.temporaryFile()
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["clipbord"], forKey: "privacyMode.sections")

        let config = ConfigStore(fileURL: file, defaults: defaults)
        #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))

        defaults.removeObject(forKey: "privacyMode.sections")
        defaults.set("not-a-boolean", forKey: "privacyMode")
        let scalarFile = try Self.temporaryFile("malformed-scalar.json")
        let scalarConfig = ConfigStore(fileURL: scalarFile, defaults: defaults)
        #expect(Set(scalarConfig.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
    }

    @Test func legacyPrivacyAllMigratesButAnExplicitEmptyListStaysOff() throws {
        let legacyFile = try Self.temporaryFile("legacy-privacy.json")
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "privacyMode")
        let legacy = ConfigStore(fileURL: legacyFile, defaults: defaults)
        #expect(Set(legacy.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))

        let explicitFile = try Self.temporaryFile("explicit-privacy.json")
        try Support.writePrivate(
            Data(#"{"privacy":[],"clipboardImageConsentVersion":1}"#.utf8),
            to: explicitFile
        )
        let explicit = ConfigStore(fileURL: explicitFile, defaults: defaults)
        #expect(explicit.privacy.isEmpty)
    }

    @Test func legacyFourSectionAllMigratesOnceButCurrentFourSectionChoiceIsPreserved() throws {
        let legacyFile = try Self.temporaryFile("legacy-four.json")
        let four = #"["clipboard","snippets","calendar","notes"]"#
        try Support.writePrivate(
            Data(#"{"privacy":\#(four),"clipboardImageConsentVersion":1}"#.utf8),
            to: legacyFile
        )
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let migrated = ConfigStore(fileURL: legacyFile, defaults: defaults)
        #expect(Set(migrated.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))

        let currentFile = try Self.temporaryFile("current-four.json")
        try Support.writePrivate(
            Data(
                #"{"privacy":\#(four),"privacyCoverageVersion":1,"clipboardImageConsentVersion":1}"#.utf8
            ),
            to: currentFile
        )
        let current = ConfigStore(fileURL: currentFile, defaults: defaults)
        #expect(Set(current.privacy) == Set(["clipboard", "snippets", "calendar", "notes"]))
    }

    @Test func missingOrNullPrivacyFailsClosedButExplicitEmptyRemainsOff() throws {
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        for (name, json) in [
            ("missing.json", #"{"clipboardImageConsentVersion":1}"#),
            ("null.json", #"{"privacy":null,"clipboardImageConsentVersion":1}"#),
        ] {
            let file = try Self.temporaryFile(name)
            try Support.writePrivate(Data(json.utf8), to: file)
            let config = ConfigStore(fileURL: file, defaults: defaults)
            #expect(Set(config.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        }
    }

    @Test func failedSecurityWritesRemainFailClosedAcrossLaunches() throws {
        let file = try Self.temporaryFile("write-failure.json")
        try Support.writePrivate(
            Data(
                #"{"showOnAllDisplays":true,"saveClipboardImages":true,"clipboardImageConsentVersion":1,"privacy":[],"privacyCoverageVersion":1,"hiddenTabs":[]}"#.utf8
            ),
            to: file
        )
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let failing = ConfigStore(fileURL: file, defaults: defaults, writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        failing.saveClipboardImages = false
        failing.privacy = PrivacyMode.Section.allCases.map(\.rawValue)
        failing.showOnAllDisplays = false
        failing.hiddenTabs = ["clipboard", "currency"]
        #expect(!failing.saveClipboardImages)
        #expect(Set(failing.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(!failing.showOnAllDisplays)
        #expect(Set(failing.hiddenTabs) == Set(["clipboard", "currency"]))
        #expect(failing.writeFailed)

        // Re-enabling a display can reveal data on a screen where the user
        // thought the panel was absent, so an undurable opt-in is rejected.
        failing.showOnAllDisplays = true
        #expect(!failing.showOnAllDisplays)

        // The original file still says capture=true/privacy=[], but the
        // separate fail-safe records must win and repair it on next launch.
        let relaunched = ConfigStore(fileURL: file, defaults: defaults)
        #expect(!relaunched.saveClipboardImages)
        #expect(Set(relaunched.privacy) == Set(PrivacyMode.Section.allCases.map(\.rawValue)))
        #expect(!relaunched.showOnAllDisplays)
        #expect(Set(relaunched.hiddenTabs) == Set(["clipboard", "currency"]))
        #expect(!relaunched.writeFailed)

        let rejectedOptIn = ConfigStore(fileURL: file, defaults: defaults, writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        rejectedOptIn.saveClipboardImages = true
        #expect(!rejectedOptIn.saveClipboardImages)
        #expect(rejectedOptIn.writeFailed)
    }

    @Test func failedPrivacyRemovalStaysCoveredInStoreAndUI() throws {
        let file = try Self.temporaryFile("privacy-write-failure.json")
        let all = PrivacyMode.Section.allCases.map(\.rawValue)
        let encoded = try JSONSerialization.data(withJSONObject: [
            "privacy": all,
            "privacyCoverageVersion": 1,
            "clipboardImageConsentVersion": 1,
        ])
        try Support.writePrivate(encoded, to: file)
        let suite = "cyclop-security-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = ConfigStore(fileURL: file, defaults: defaults, writeData: { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        })
        let privacy = PrivacyMode(
            rawSections: config.privacy,
            persist: { config.privacy = $0; return config.privacy }
        )

        privacy.setCoveringAll(false)
        #expect(Set(config.privacy) == Set(all))
        #expect(privacy.coversAll)
        #expect(config.writeFailed)
    }

    @Test func clipboardImageDimensionsAreBoundedWithoutOverflow() {
        #expect(ClipboardStore.imageDimensionsAreSafe(width: 8_000, height: 5_000))
        #expect(!ClipboardStore.imageDimensionsAreSafe(width: 8_001, height: 5_000))
        #expect(!ClipboardStore.imageDimensionsAreSafe(width: Int.max, height: Int.max))
        #expect(!ClipboardStore.imageDimensionsAreSafe(width: 0, height: 100))
    }

    @Test func screenshotVaultRefusesOversizeAndOverQuotaWrites() {
        #expect(ScreenshotVault.canSave(byteCount: 1, usage: (files: 0, bytes: 0)))
        #expect(!ScreenshotVault.canSave(
            byteCount: ScreenshotVault.maxFileBytes + 1,
            usage: (files: 0, bytes: 0)
        ))
        #expect(!ScreenshotVault.canSave(
            byteCount: 1,
            usage: (files: ScreenshotVault.maxFiles, bytes: 0)
        ))
        #expect(!ScreenshotVault.canSave(
            byteCount: 2,
            usage: (files: 0, bytes: ScreenshotVault.maxTotalBytes - 1)
        ))
    }

    @Test func copyingAnImageFromTheShelfUsesABoundedRead() throws {
        let file = try Self.temporaryFile("copy.png")
        try Data("12345".utf8).write(to: file)
        #expect(ShelfStore.boundedData(at: file, maxBytes: 4) == nil)
        #expect(ShelfStore.boundedData(at: file, maxBytes: 5) == Data("12345".utf8))
    }

    @Test func clipboardHistoryRefusesUnboundedTextRetention() {
        #expect(ClipboardStore.textAcceptedForHistory("  \n") == nil)
        let accepted = String(repeating: "a", count: ClipboardStore.maxRetainedTextBytes)
        #expect(ClipboardStore.textAcceptedForHistory(accepted) == accepted)
        #expect(ClipboardStore.textAcceptedForHistory(accepted + "b") == nil)
        // The limit is bytes, not grapheme count.
        let emoji = String(repeating: "😀", count: ClipboardStore.maxRetainedTextBytes / 4 + 1)
        #expect(ClipboardStore.textAcceptedForHistory(emoji) == nil)
    }

    @Test func networkAllowlistRejectsLookalikesAndNonHTTPSURLs() throws {
        let hosts: Set<String> = ["spotifycdn.com"]
        #expect(NetworkPolicy.allows(try #require(URL(string: "https://i.scdn.co/image/abc")), hosts: ["scdn.co"]))
        #expect(NetworkPolicy.allows(try #require(URL(string: "https://image.spotifycdn.com/a")), hosts: hosts))
        #expect(!NetworkPolicy.allows(try #require(URL(string: "http://image.spotifycdn.com/a")), hosts: hosts))
        #expect(!NetworkPolicy.allows(try #require(URL(string: "https://spotifycdn.com.evil.example/a")), hosts: hosts))
        #expect(!NetworkPolicy.allows(try #require(URL(string: "https://user@spotifycdn.com/a")), hosts: hosts))
        #expect(!NetworkPolicy.allows(try #require(URL(string: "https://spotifycdn.com:8443/a")), hosts: hosts))

        let artwork = NetworkPolicy.Destination(host: "i.scdn.co", pathPrefix: "/image/")
        #expect(artwork.allows(try #require(URL(string: "https://i.scdn.co/image/abc"))))
        #expect(!artwork.allows(try #require(URL(string: "https://sub.i.scdn.co/image/abc"))))
        #expect(!artwork.allows(try #require(URL(string: "https://i.scdn.co/not-image/abc"))))
    }

    @Test func boundedNetworkAccumulatorStopsAtTheFirstExcessByte() {
        #expect(NetworkPolicy.canAppend(chunkBytes: 4, accumulatedBytes: 6, maxBytes: 10))
        #expect(!NetworkPolicy.canAppend(chunkBytes: 5, accumulatedBytes: 6, maxBytes: 10))
        #expect(!NetworkPolicy.canAppend(chunkBytes: 0, accumulatedBytes: 11, maxBytes: 10))
    }

    @Test func currencyDateValidationRejectsMalformedUnicodeWithoutIndexingPastTheString() {
        #expect(CurrencyStore.isValidDateStamp("2026-09-18"))
        #expect(!CurrencyStore.isValidDateStamp("2026-02-30"))
        // Ten UTF-8 bytes, but only four Characters. Character-offset indexing
        // used to trap here on an untrusted response.
        #expect(!CurrencyStore.isValidDateStamp("😀😀aa"))
    }

    @Test func malformedCalendarVisibilityPreferenceIsUnavailableNotShowEverything() {
        #expect(CalendarStore.parseHiddenCalendarIdentifiers(nil) == Set<String>())
        #expect(
            CalendarStore.parseHiddenCalendarIdentifiers([
                "account-a": ["private", "shared"],
                "account-b": ["holidays"],
            ]) == Set(["private", "shared", "holidays"])
        )
        #expect(CalendarStore.parseHiddenCalendarIdentifiers(["unexpected", "shape"]) == nil)
        #expect(CalendarStore.parseHiddenCalendarIdentifiers(["account": [1, 2]]) == nil)

        #expect(CalendarVisibility.parseOverrides(nil) == [:])
        #expect(CalendarVisibility.parseOverrides(["private": true, "shared": false]) == [
            "private": true,
            "shared": false,
        ])
        #expect(CalendarVisibility.parseOverrides(["private": 1]) == nil)
        #expect(CalendarVisibility.parseOverrides(["unexpected"]) == nil)
    }

    @Test func sensitiveFilesAreWrittenOwnerOnly() throws {
        let file = try Self.temporaryFile("secret.txt")
        try Support.writePrivate(Data("secret".utf8), to: file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)

        let folderAttributes = try FileManager.default.attributesOfItem(
            atPath: file.deletingLastPathComponent().path
        )
        let folderPermissions = try #require(folderAttributes[.posixPermissions] as? NSNumber)
        #expect(folderPermissions.intValue & 0o777 == 0o700)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try Support.writePrivate(Data("replacement".utf8), to: file)
        let rewritten = try FileManager.default.attributesOfItem(atPath: file.path)
        let rewrittenPermissions = try #require(rewritten[.posixPermissions] as? NSNumber)
        #expect(rewrittenPermissions.intValue & 0o777 == 0o600)
    }

    @Test func existingScreenshotPermissionsAreTightenedWithoutFollowingSymlinks() throws {
        let marker = try Self.temporaryFile("marker")
        let folder = marker.deletingLastPathComponent()
        let image = folder.appendingPathComponent("old.png")
        let unrelated = folder.appendingPathComponent("readme.txt")
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyclop-outside-\(UUID().uuidString).png")
        let link = folder.appendingPathComponent("linked.png")
        defer {
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.removeItem(at: outside)
        }

        try Data("png".utf8).write(to: image)
        try Data("text".utf8).write(to: unrelated)
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        for file in [image, unrelated, outside] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        }

        ScreenshotVault.hardenExistingStorage(at: folder)

        func permissions(_ url: URL) throws -> Int {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
        }
        #expect(try permissions(folder) == 0o700)
        #expect(try permissions(image) == 0o600)
        #expect(try permissions(unrelated) == 0o644)
        #expect(try permissions(outside) == 0o644)
    }

    @Test func privateStorageRejectsAnExistingDirectorySymlink() throws {
        let marker = try Self.temporaryFile("marker")
        let root = marker.deletingLastPathComponent()
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        var rejected = false
        do {
            try Support.makePrivateDirectory(at: link)
        } catch {
            rejected = true
        }
        #expect(rejected)

        rejected = false
        do {
            try Support.makePrivateDirectory(at: link.appendingPathComponent("child", isDirectory: true))
        } catch {
            rejected = true
        }
        #expect(rejected)
    }

    @Test func privateFileProtectionDoesNotFollowSymlinks() throws {
        let marker = try Self.temporaryFile("marker")
        let root = marker.deletingLastPathComponent()
        let target = root.appendingPathComponent("target.txt")
        let link = root.appendingPathComponent("link.txt")
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("outside".utf8).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.path)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        Support.protectFileIfPresent(at: link)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o644)

        var rejected = false
        do {
            try Support.writePrivate(Data("replacement".utf8), to: link)
        } catch {
            rejected = true
        }
        #expect(rejected)
        #expect(try Data(contentsOf: target) == Data("outside".utf8))
    }

    @Test func screenshotMaintenanceRejectsASymlinkedParent() throws {
        let marker = try Self.temporaryFile("marker")
        let root = marker.deletingLastPathComponent()
        let targetParent = root.appendingPathComponent("outside", isDirectory: true)
        let targetFolder = targetParent.appendingPathComponent("Cyclop", isDirectory: true)
        let image = targetFolder.appendingPathComponent("keep.png")
        let parentLink = root.appendingPathComponent("Pictures", isDirectory: true)
        let unsafeFolder = parentLink.appendingPathComponent("Cyclop", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        try Data("png".utf8).write(to: image)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: targetFolder.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: image.path)
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: targetParent)

        ScreenshotVault.hardenExistingStorage(at: unsafeFolder)
        #expect(ScreenshotVault.usage(at: unsafeFolder) == (0, 0))
        ScreenshotVault.clear(at: unsafeFolder)

        #expect(FileManager.default.fileExists(atPath: image.path))
        let folderMode = try #require(
            FileManager.default.attributesOfItem(atPath: targetFolder.path)[.posixPermissions] as? NSNumber
        )
        let imageMode = try #require(
            FileManager.default.attributesOfItem(atPath: image.path)[.posixPermissions] as? NSNumber
        )
        #expect(folderMode.intValue & 0o777 == 0o755)
        #expect(imageMode.intValue & 0o777 == 0o644)
    }
}
