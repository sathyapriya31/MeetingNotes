import EventKit
import Foundation

/// The calendar event a recording belongs to.
struct CalendarMeeting: Equatable {
    var eventID: String?
    var title: String
    var start: Date
    var end: Date
    /// Display names of the other people on the invite (the user excluded,
    /// declined invitees and rooms/resources dropped).
    var attendees: [String]
}

/// Reads the user's calendars via EventKit to find the event a recording is
/// for, so the meeting gets its real title and the attendee list can be used to
/// name speakers. Read-only; nothing is written to the calendar.
final class CalendarService {
    static let enabledKey = "calendarIntegrationEnabled"

    /// On by default; toggled in Settings.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    static var authorizationStatus: EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    private let store = EKEventStore()

    /// Prompts for access the first time; true when events can be read.
    func requestAccessIfNeeded() async -> Bool {
        switch Self.authorizationStatus {
        case .fullAccess:
            return true
        case .notDetermined:
            return (try? await store.requestFullAccessToEvents()) ?? false
        default:
            return false
        }
    }

    /// The event most likely being recorded at `date`, or nil when the
    /// integration is off, access is denied, or nothing fits.
    func meeting(around date: Date) async -> CalendarMeeting? {
        guard Self.isEnabled, await requestAccessIfNeeded() else { return nil }

        // Events that started up to 12 h ago (long meetings) or start within the hour.
        let predicate = store.predicateForEvents(
            withStart: date.addingTimeInterval(-12 * 3600),
            end: date.addingTimeInterval(3600),
            calendars: nil
        )
        let events = store.events(matching: predicate)
        let candidates = events.map { event in
            EventCandidate(
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                declinedByUser: event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false,
                attendeeCount: event.attendees?.count ?? 0
            )
        }
        guard let index = Self.pick(candidates, at: date) else { return nil }
        let event = events[index]

        return CalendarMeeting(
            eventID: event.eventIdentifier,
            title: (event.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: event.startDate,
            end: event.endDate,
            attendees: Self.attendeeNames(for: event)
        )
    }

    // MARK: - Event choice

    struct EventCandidate {
        var start: Date
        var end: Date
        var isAllDay: Bool
        var declinedByUser: Bool
        var attendeeCount: Int
    }

    /// Index of the best event for a recording started at `date`: an event in
    /// progress or starting within `lead`, skipping all-day and declined events.
    /// Events with invitees win over solo blocks (e.g. "Focus time"); ties go to
    /// the event whose start is closest to `date`.
    static func pick(_ candidates: [EventCandidate], at date: Date, lead: TimeInterval = 15 * 60) -> Int? {
        candidates.indices
            .filter { i in
                let c = candidates[i]
                return !c.isAllDay && !c.declinedByUser
                    && c.start <= date.addingTimeInterval(lead)
                    && c.end > date
            }
            .min { a, b in
                let ca = candidates[a], cb = candidates[b]
                let aHas = ca.attendeeCount > 0, bHas = cb.attendeeCount > 0
                if aHas != bHas { return aHas }
                return abs(ca.start.timeIntervalSince(date)) < abs(cb.start.timeIntervalSince(date))
            }
    }

    // MARK: - Attendees

    private static func attendeeNames(for event: EKEvent) -> [String] {
        var participants = event.attendees ?? []
        if let organizer = event.organizer { participants.append(organizer) }

        var names: [String] = []
        for p in participants {
            guard !p.isCurrentUser,
                  p.participantStatus != .declined,
                  p.participantType == .person || p.participantType == .unknown,
                  let name = displayName(name: p.name, url: p.url),
                  !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            else { continue }
            names.append(name)
        }
        return names
    }

    /// The participant's name, or one derived from their email
    /// ("samantha.lee@x.com" → "Samantha Lee") when the invite only has an address.
    static func displayName(name: String?, url: URL?) -> String? {
        if let name = name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, !name.contains("@") {
            return name
        }
        let address = name?.contains("@") == true ? name! : (url?.absoluteString ?? "")
        let local = address
            .replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
            .split(separator: "@").first.map(String.init) ?? ""
        let words = local
            .split(whereSeparator: { "._-+".contains($0) })
            .map(String.init)
            .filter { !$0.isEmpty && !$0.allSatisfy(\.isNumber) }
        guard !words.isEmpty else { return nil }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }.joined(separator: " ")
    }
}
