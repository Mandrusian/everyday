import Foundation
import EventKit

/// Reads today's events and mirrors tasks to Apple Reminders (optional). Uses the system's own permission prompts.
public final class CalendarService: @unchecked Sendable {
    private let store = EKEventStore()
    public init() {}

    public enum Access { case granted, denied, notDetermined }

    public var calendarAccess: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }
    public var reminderAccess: Access {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    public func requestCalendar() async -> Bool { (try? await store.requestFullAccessToEvents()) ?? false }
    public func requestReminders() async -> Bool { (try? await store.requestFullAccessToReminders()) ?? false }

    public func upcoming(hours: Int = 36) -> [CalendarEvent] {
        guard calendarAccess == .granted else { return [] }
        let start = Date()
        let end = start.addingTimeInterval(Double(hours) * 3600)
        let pred = store.predicateForEvents(withStart: Calendar.current.startOfDay(for: start), end: end, calendars: nil)
        return store.events(matching: pred).filter { $0.endDate > start }.sorted { $0.startDate < $1.startDate }
            .map { CalendarEvent(id: $0.eventIdentifier ?? UUID().uuidString, title: $0.title ?? "Untitled", start: $0.startDate, end: $0.endDate, isAllDay: $0.isAllDay) }
    }

    // Reminders mirror
    public func addReminder(for task: TaskItem) -> String? {
        guard reminderAccess == .granted, let cal = store.defaultCalendarForNewReminders() else { return nil }
        let r = EKReminder(eventStore: store)
        r.title = task.title; r.notes = task.notes.isEmpty ? task.sourceDescription : task.notes; r.calendar = cal
        if let d = task.due { r.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: d) }
        r.priority = task.priority == .high ? 1 : task.priority == .medium ? 5 : 9
        do { try store.save(r, commit: true); return r.calendarItemIdentifier } catch { return nil }
    }

    public func setReminderCompleted(_ id: String, _ done: Bool) {
        guard reminderAccess == .granted, let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        r.isCompleted = done
        try? store.save(r, commit: true)
    }

    public func removeReminder(_ id: String) {
        guard reminderAccess == .granted, let r = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        try? store.remove(r, commit: true)
    }
}
