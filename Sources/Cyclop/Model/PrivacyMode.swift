import AppKit
import Combine

/// Hides what the panel holds behind a field of drifting dots, for screens that
/// somebody else is watching.
///
/// Chosen per section rather than one switch for everything: the tabs hold
/// different things, and somebody streaming their desk may care about the
/// clipboard and not about the calendar, or the other way round. The menu still
/// offers "All" first, because that is the answer most of the time and the one
/// nobody has to think about.
///
/// The choice outlives launches — forgetting to turn covering *on* is what
/// costs something, so it must not depend on remembering.
///
/// Nothing here decides *what* is a secret. Guessing at addresses and card
/// numbers with a regular expression fails silently and tells the user about it
/// only afterwards, on the recording; covering everything in a chosen section
/// is predictable, and predictability is the feature.
@MainActor
final class PrivacyMode: ObservableObject {
    enum Section: String, CaseIterable, Identifiable {
        case media, shelf, clipboard, snippets, calendar, translate, currency, notes, teleprompter

        var id: String { rawValue }

        /// The tab's own name — the menu and the panel must not disagree about
        /// what a section is called.
        var title: String {
            switch self {
            case .media: return localized("Music")
            case .shelf: return localized("Shelf")
            case .clipboard: return localized("Clipboard")
            case .snippets: return localized("Snippets")
            case .calendar: return localized("Calendar")
            case .translate: return localized("Translate")
            case .currency: return localized("Currency")
            case .notes: return localized("Notes")
            case .teleprompter: return localized("Teleprompter")
            }
        }
    }

    /// What the user has uncovered by hand, by row id. Cleared whenever the
    /// panel folds: a row uncovered once must not still be uncovered the next
    /// time the panel opens, which would be exactly when nobody is looking at
    /// it and the camera is.
    @Published private(set) var revealed: Set<String> = []

    /// Whole panes temporarily uncovered with the central eye, keyed by the
    /// physical panel that asked. Revealing a private pane on one display must
    /// not reveal the same shared tab on a second display being recorded.
    @Published private var revealedSectionsBySession: [UUID: Set<Section>] = [:]

    @Published private(set) var sections: Set<Section>

    /// Returns the effective durable state. Privacy-decreasing writes can be
    /// rejected, so assuming the requested state would make the UI fail open
    /// even when ConfigStore correctly kept the cover in place.
    private let writer: ([String]) -> [String]
    private let changesAllowed: () -> Bool

    /// Persisted in `config.json` (#67) — the old `UserDefaults` keys, one
    /// bool for everything and then one array of sections, were folded into
    /// it once and are no longer read here.
    init(
        rawSections: [String]? = nil,
        persist: (([String]) -> [String])? = nil,
        changesAllowed: (() -> Bool)? = nil
    ) {
        let usesSharedConfig = rawSections == nil && persist == nil
        let raw = rawSections ?? ConfigStore.shared.privacy
        writer = persist ?? {
            ConfigStore.shared.privacy = $0
            return ConfigStore.shared.privacy
        }
        self.changesAllowed = changesAllowed ?? {
            usesSharedConfig ? !ConfigStore.shared.fileBroken : true
        }

        sections = Set(raw.compactMap(Section.init(rawValue:)))
    }

    // MARK: - Sections

    /// Whether this section covers its contents at all — also what decides if
    /// the eye is offered on its rows. The row-level views use this form only
    /// after an outer per-panel cover has admitted them; when any panel has
    /// revealed the whole section, its rows may render normally. Other panels
    /// still stop at `covers(_:for:)` and never mount those rows.
    func covers(_ section: Section) -> Bool {
        isEnabled(section) && !revealedSectionsBySession.values.contains(where: { $0.contains(section) })
    }

    func isEnabled(_ section: Section) -> Bool { sections.contains(section) }

    func covers(_ section: Section, for session: UUID) -> Bool {
        isEnabled(section) && !(revealedSectionsBySession[session]?.contains(section) ?? false)
    }

    var coversAll: Bool { sections.count == Section.allCases.count }
    var coversAny: Bool { !sections.isEmpty }

    func setCovering(_ section: Section, _ on: Bool) {
        guard changesAllowed() else { return }
        if on { sections.insert(section) } else { sections.remove(section) }
        for session in Array(revealedSectionsBySession.keys) {
            revealedSectionsBySession[session]?.remove(section)
        }
        revealedSectionsBySession = revealedSectionsBySession.filter { !$0.value.isEmpty }
        revealed.removeAll()
        persist()
    }

    func setCoveringAll(_ on: Bool) {
        guard changesAllowed() else { return }
        sections = on ? Set(Section.allCases) : []
        revealedSectionsBySession.removeAll()
        revealed.removeAll()
        persist()
    }

    private func persist() {
        let effective = writer(sections.map(\.rawValue).sorted())
        sections = Set(effective.compactMap(Section.init(rawValue:)))
        if !coversAny { revealed.removeAll() }
    }

    /// Uncovers a complete pane until the panel folds. The covered branch does
    /// not contain the real pane, so this is an explicit transition rather than
    /// an opacity trick that could still leak through accessibility or focus.
    func reveal(_ section: Section, for session: UUID) {
        guard isEnabled(section) else { return }
        var sections = revealedSectionsBySession[session] ?? []
        sections.insert(section)
        revealedSectionsBySession[session] = sections
    }

    func cover(_ section: Section, for session: UUID) {
        guard var sections = revealedSectionsBySession[session] else { return }
        sections.remove(section)
        if sections.isEmpty {
            revealedSectionsBySession.removeValue(forKey: session)
        } else {
            revealedSectionsBySession[session] = sections
        }
        revealed.removeAll()
    }

    func coverEverything(for session: UUID) {
        revealedSectionsBySession.removeValue(forKey: session)
        revealed.removeAll()
    }

    // MARK: - Rows

    /// True when this particular row has to be covered right now.
    func hides(_ section: Section, _ id: String) -> Bool {
        covers(section) && !revealed.contains(id)
    }

    func reveal(_ id: String) {
        revealed.insert(id)
    }

    func toggle(_ id: String) {
        if revealed.contains(id) { revealed.remove(id) } else { revealed.insert(id) }
    }

    /// Back to covered — called when the panel folds.
    func coverEverything() {
        revealed.removeAll()
        revealedSectionsBySession.removeAll()
    }
}
