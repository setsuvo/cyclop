import AppKit
import EventKit

/// Bounded, Sendable shape copied from EventKit on a worker queue. EKEvent is
/// not allowed to escape that queue; only the fields the panel actually uses
/// cross back to the main actor.
private struct CalendarEventSnapshot: Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarIdentifier: String
    let link: URL?
}

private enum CalendarInputPolicy {
    static let maxCalendars = 512
    static let maxOccurrencesScanned = 10_000
    static let maxMeetings = 512
    static let maxTitleScalars = 512
    static let maxCalendarTitleScalars = 256

    private static let bidiControls: Set<UInt32> = [
        0x200E, 0x200F, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
        0x2066, 0x2067, 0x2068, 0x2069,
    ]

    /// Calendar titles and invitation titles are remote-controlled display
    /// text. Collapse controls/line breaks and remove bidi overrides so one
    /// row cannot impersonate or visually reorder the rest of the panel.
    static func displayText(_ text: String?, maxScalars: Int) -> String {
        guard let text, maxScalars > 0 else { return "" }
        var output = ""
        var lastWasSpace = true
        for scalar in text.unicodeScalars.prefix(maxScalars) {
            if bidiControls.contains(scalar.value) { continue }
            if CharacterSet.whitespacesAndNewlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar) {
                if !lastWasSpace {
                    output.append(" ")
                    lastWasSpace = true
                }
            } else {
                output.unicodeScalars.append(scalar)
                lastWasSpace = false
            }
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private enum CalendarEventLoader {
    struct Result: Sendable {
        let events: [CalendarEventSnapshot]
        let truncated: Bool
    }

    /// EventKit's array-returning API is synchronous and unbounded. Enumerate
    /// on a private serial queue instead, stop after a hard occurrence ceiling,
    /// and retain only the earliest fixed-size set before parsing any text.
    static func load(calendarIdentifiers: Set<String>, start: Date, end: Date) -> Result {
        let store = EKEventStore()
        let calendars = store.calendars(for: .event).filter {
            calendarIdentifiers.contains($0.calendarIdentifier)
        }
        guard !calendars.isEmpty else { return Result(events: [], truncated: false) }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        var scanned = 0
        var truncated = false
        var earliest: [EKEvent] = []

        store.enumerateEvents(matching: predicate) { event, stop in
            scanned += 1
            guard scanned <= CalendarInputPolicy.maxOccurrencesScanned else {
                truncated = true
                stop.pointee = true
                return
            }
            guard !event.isAllDay, event.status != .canceled,
                  let eventStart = event.startDate, let eventEnd = event.endDate,
                  eventEnd > eventStart else { return }

            if earliest.count < CalendarInputPolicy.maxMeetings {
                earliest.append(event)
                return
            }
            guard let latestIndex = earliest.indices.max(by: {
                earliest[$0].startDate < earliest[$1].startDate
            }), eventStart < earliest[latestIndex].startDate else { return }
            earliest[latestIndex] = event
        }

        let snapshots = earliest.sorted { $0.startDate < $1.startDate }.map { event in
            let rawIdentifier = event.eventIdentifier ?? event.calendarItemIdentifier
            let identifier = String(rawIdentifier.prefix(1_024))
            return CalendarEventSnapshot(
                id: identifier,
                title: CalendarInputPolicy.displayText(
                    event.title,
                    maxScalars: CalendarInputPolicy.maxTitleScalars
                ),
                start: event.startDate,
                end: event.endDate,
                calendarIdentifier: event.calendar.calendarIdentifier,
                link: MeetingLink.find(in: event)
            )
        }
        return Result(events: snapshots, truncated: truncated)
    }
}

/// Today's meetings, and the link that joins the next one.
///
/// Access is requested only when the user first opens the calendar tab: it is
/// the one permission Cyclop needs at all, and nobody should be asked for it
/// just because the app launched.
@MainActor
final class CalendarStore: ObservableObject {
    enum Access {
        case notRequested
        case granted
        case denied
    }

    struct Meeting: Identifiable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendarColor: NSColor
        let link: URL?
        let provider: String?

        var isRunning: Bool {
            let now = Date()
            return start <= now && now < end
        }

        func overlaps(_ other: Meeting) -> Bool {
            start < other.end && end > other.start
        }
    }

    /// One calendar as the picker in the status-bar menu shows it (#36).
    struct CalendarOption: Identifiable {
        let id: String
        let title: String
        let isShown: Bool
    }

    @Published private(set) var access: Access = .notRequested
    @Published private(set) var meetings: [Meeting] = []
    /// Recomputed on a timer so the countdown in the header stays honest.
    @Published private(set) var now = Date()

    private let store = EKEventStore()
    private let reloadQueue = DispatchQueue(label: "com.cyclop.calendar.reload", qos: .utility)
    private var reloadGeneration = 0
    private var calendarColors: [String: NSColor] = [:]
    private var timer: Timer?
    private var observer: Any?
    /// Whether the panel is open. The half-minute tick serves eyes only — it
    /// keeps the countdown honest and drops meetings as they end — so it runs
    /// exactly while there are eyes.
    private var isActive = false
    /// A day-long horizon leaves the tab empty every evening, which is exactly
    /// when one wonders what tomorrow looks like. A week is still glanceable
    /// because only the next meeting gets the large treatment.
    private let horizon: TimeInterval = 7 * 24 * 3600

    var next: Meeting? {
        meetings.first { $0.end > Date() }
    }

    var upcoming: [Meeting] {
        guard let next else { return [] }
        return meetings.filter { $0.id != next.id && $0.end > Date() }
    }

    // MARK: - Lifecycle

    func start() {
        access = Self.currentAccess()
        guard access == .granted else { return }
        observe()
        reload()
    }

    func stop() {
        reloadGeneration &+= 1
        stopTimer()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    /// Panel opened or closed. Opening refreshes at once — the countdown must
    /// be right on the first frame, not thirty seconds in — and starts the
    /// tick; closing stops it. Meetings still change while the panel is
    /// closed, but `EKEventStoreChanged` covers that without a clock.
    func setActive(_ active: Bool) {
        isActive = active
        guard active else { return stopTimer() }
        guard access == .granted else { return }
        tick()
        startTimer()
    }

    /// Called when the calendar tab is shown. Never prompts — it only notices
    /// that access was granted elsewhere, or since last launch.
    func refreshAccess() {
        access = Self.currentAccess()
        guard access == .granted else { return }
        observe()
        reload()
        if isActive { startTimer() }
    }

    /// Prompts. Only ever called from the button the user presses.
    func requestAccess() {
        guard Self.currentAccess() == .notRequested else {
            refreshAccess()
            return
        }
        // EventKit replies on an XPC queue.  This must remain a nonisolated
        // callback; the Task performs the only hop back to the main actor.
        store.requestFullAccessToEvents { @Sendable [weak self] granted, _ in
            Task { @MainActor in
                guard let self else { return }
                self.access = granted ? .granted : .denied
                guard granted else { return }
                self.observe()
                self.reload()
                if self.isActive { self.startTimer() }
            }
        }
    }

    private static func currentAccess() -> Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notRequested
        default: return .denied
        }
    }

    /// Calendars unchecked in Calendar.app's sidebar. EventKit has no public
    /// notion of this at all — "shown or not" is Calendar.app's own UI state,
    /// not calendar data, so it lives in Calendar.app's preferences instead.
    /// The identifiers there are the same ones EventKit hands out: Calendar.app
    /// and EventKit both read the same underlying calendar store.
    private static func hiddenCalendarIdentifiers() -> Set<String>? {
        let stored = CFPreferencesCopyAppValue(
            "DisabledCalendars" as CFString, "com.apple.iCal" as CFString
        )
        let parsed = parseHiddenCalendarIdentifiers(stored)
        if stored != nil, parsed == nil {
            NSLog("Cyclop: com.apple.iCal DisabledCalendars is no longer [String: [String]] — only calendars explicitly enabled in Cyclop will be shown")
        }
        return parsed
    }

    /// `nil` means the preference exists but its private Calendar.app schema
    /// is no longer understood. That must remain distinct from an absent key,
    /// which legitimately means nothing is hidden.
    static func parseHiddenCalendarIdentifiers(_ stored: Any?) -> Set<String>? {
        guard let stored else { return [] }
        guard let disabled = stored as? [String: [String]] else { return nil }
        return Set(disabled.values.flatMap { $0 })
    }

    private func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        // Half a minute is enough for a countdown shown in whole minutes, and
        // the generous tolerance lets the system fold the wake-up into others.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        now = Date()
        // Drop finished meetings without a full refetch.
        if meetings.contains(where: { $0.end <= now }) {
            meetings.removeAll { $0.end <= now }
        }
    }

    // MARK: - Loading

    func reload() {
        guard access == .granted else { return }
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let hidden = Self.hiddenCalendarIdentifiers()
        let calendars = store.calendars(for: .event)
            .prefix(CalendarInputPolicy.maxCalendars)
            .filter { calendar in
                if let hidden {
                    return CalendarVisibility.isShown(calendar.calendarIdentifier, hiddenInSystem: hidden)
                }
                // Calendar.app's private preference changed shape. Preserve
                // only choices the user explicitly made inside Cyclop.
                return CalendarVisibility.isExplicitlyShown(calendar.calendarIdentifier)
            }
        // EventKit treats an empty array the same as nil — "no restriction",
        // not "restrict to nothing" — so unchecking every calendar has to be
        // handled before it ever reaches the predicate, or it would silently
        // show everything, the one outcome the checkbox promised not to.
        guard !calendars.isEmpty else {
            meetings = []
            now = Date()
            return
        }
        let start = Date()
        let end = start.addingTimeInterval(horizon)
        let identifiers = Set(calendars.map(\.calendarIdentifier))
        calendarColors = Dictionary(uniqueKeysWithValues: calendars.map {
            ($0.calendarIdentifier, $0.color ?? .systemBlue)
        })
        let colors = calendarColors

        reloadQueue.async { [weak self] in
            let result = CalendarEventLoader.load(
                calendarIdentifiers: identifiers,
                start: start,
                end: end
            )
            if result.truncated {
                NSLog("Cyclop: calendar occurrence limit reached; showing the earliest bounded set")
            }
            Task { @MainActor [weak self] in
                guard let self, self.reloadGeneration == generation, self.access == .granted else {
                    return
                }
                self.meetings = result.events.map { event in
                    Meeting(
                        id: event.id,
                        title: event.title.isEmpty ? localized("Untitled") : event.title,
                        start: event.start,
                        end: event.end,
                        calendarColor: colors[event.calendarIdentifier] ?? .systemBlue,
                        link: event.link,
                        provider: event.link.flatMap(MeetingLink.provider)
                    )
                }
                self.now = Date()
            }
        }
    }

    /// Calendars for the status-bar picker (#36), each labelled with the pick
    /// already in effect. Empty until access is granted — the menu checks
    /// that separately and shows a hint instead.
    var calendarOptions: [CalendarOption] {
        guard access == .granted else { return [] }
        let hidden = Self.hiddenCalendarIdentifiers()
        return store.calendars(for: .event)
            .prefix(CalendarInputPolicy.maxCalendars)
            .sorted { $0.title < $1.title }
            .map { calendar in
                CalendarOption(
                    id: calendar.calendarIdentifier,
                    title: CalendarInputPolicy.displayText(
                        calendar.title,
                        maxScalars: CalendarInputPolicy.maxCalendarTitleScalars
                    ),
                    isShown: hidden.map {
                        CalendarVisibility.isShown(calendar.calendarIdentifier, hiddenInSystem: $0)
                    } ?? CalendarVisibility.isExplicitlyShown(calendar.calendarIdentifier)
                )
            }
    }

    /// Flips one calendar's pick and reloads at once: the menu that changed
    /// it closes right after, so the panel has to already be showing the
    /// new answer by then.
    func setCalendarShown(_ shown: Bool, identifier: String) {
        CalendarVisibility.setShown(shown, for: identifier)
        reload()
    }

    func join(_ meeting: Meeting) {
        // Checked a second time, at the point of opening. The link comes out
        // of an event, and an event can be sent by anyone: a calendar
        // invitation needs no acquaintance, only an address.
        guard let link = meeting.link, MeetingLink.isJoinable(link) else { return }
        NSWorkspace.shared.open(link)
    }

    func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

/// Whether the panel shows a calendar, kept apart from whether Calendar.app
/// does (#36). A calendar Cyclop has never been asked about takes the answer
/// `hiddenCalendarIdentifiers()` normally gives. If that private Calendar.app
/// preference ever changes shape, only an explicit Cyclop opt-in is accepted
/// until its meaning is understood again. Once picked here, that pick holds
/// regardless of what the checkbox in Calendar.app does afterwards. Hiding a
/// calendar there and hiding it in the panel over the notch are different
/// intents: someone might keep a noisy shared calendar checked in Calendar
/// itself, for availability, while wanting only their own meetings in the
/// glance the panel gives.
enum CalendarVisibility {
    private static let key = "calendarVisibilityOverrides"

    /// nil means the preference is present but malformed. It is intentionally
    /// different from an absent preference (an empty dictionary).
    private static var overrides: [String: Bool]? {
        get { parseOverrides(UserDefaults.standard.object(forKey: key)) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    static func parseOverrides(_ stored: Any?) -> [String: Bool]? {
        guard let stored else { return [:] }
        guard let dictionary = stored as? [String: Any] else { return nil }
        var parsed: [String: Bool] = [:]
        for (key, value) in dictionary {
            guard let number = value as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
            parsed[key] = number.boolValue
        }
        return parsed
    }

    static func isShown(_ identifier: String, hiddenInSystem: Set<String>) -> Bool {
        guard let overrides else { return false }
        return overrides[identifier] ?? !hiddenInSystem.contains(identifier)
    }

    static func isExplicitlyShown(_ identifier: String) -> Bool {
        overrides?[identifier] == true
    }

    static func setShown(_ shown: Bool, for identifier: String) {
        var current = overrides ?? [:]
        current[identifier] = shown
        overrides = current
    }
}

/// Finds the video call in an event. Providers put the link wherever they like:
/// Google Meet in the notes, Zoom often in the location, Teams in both.
///
/// Only links to the known hosts are ever returned, and only over https. An
/// event is not the user's own text: anyone who knows the address can put one
/// in the calendar, and whatever it carries would otherwise arrive as a button
/// that says "Join" and opens it. A meeting with an unrecognised link keeps its
/// row and loses the button — the link is still in the event, one click away in
/// Calendar, where it looks like what it is.
enum MeetingLink {
    private static let hosts = [
        "meet.google.com": "Google Meet",
        "zoom.us": "Zoom",
        "teams.microsoft.com": "Teams",
        "teams.live.com": "Teams",
        "webex.com": "Webex",
        "whereby.com": "Whereby",
        "meet.jit.si": "Jitsi",
        "discord.gg": "Discord",
        "telemost.yandex.ru": "Телемост",
    ]

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func find(in event: EKEvent) -> URL? {
        let haystacks = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }
        for text in haystacks {
            if let url = firstKnownLink(in: text) { return url }
        }
        return nil
    }

    /// Everything the join button is allowed to open.
    static func isJoinable(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && provider(for: url) != nil
    }

    private static func firstKnownLink(in text: String) -> URL? {
        guard let detector else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in detector.matches(in: text, range: range) {
            guard let url = match.url,
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased() else { continue }
            if hosts.keys.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return url }
        }
        return nil
    }

    static func provider(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return hosts.first { host == $0.key || host.hasSuffix(".\($0.key)") }?.value
    }
}
