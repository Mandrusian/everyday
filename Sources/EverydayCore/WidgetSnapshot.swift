import Foundation

/// What the desktop widgets show. The app writes it; the widget extension reads it (see Sources/EverydayWidgets).
/// Keep the field names in step with `Snap` in the widget target.
public struct WidgetSnapshot: Codable, Sendable {
    public struct Weather: Codable, Sendable { public var city: String; public var temp: Double; public var condition: String; public var high: Double; public var low: Double; public var hours: [Hour]
        public init(city: String, temp: Double, condition: String, high: Double, low: Double, hours: [Hour]) { self.city = city; self.temp = temp; self.condition = condition; self.high = high; self.low = low; self.hours = hours } }
    public struct Hour: Codable, Sendable { public var date: Date; public var temp: Double; public init(date: Date, temp: Double) { self.date = date; self.temp = temp } }
    public struct Event: Codable, Sendable { public var title: String; public var start: Date; public var allDay: Bool; public init(title: String, start: Date, allDay: Bool) { self.title = title; self.start = start; self.allDay = allDay } }
    public struct Item: Codable, Sendable { public var who: String; public var what: String; public init(who: String, what: String) { self.who = who; self.what = what } }
    public struct Story: Codable, Sendable { public var title: String; public var source: String; public init(title: String, source: String) { self.title = title; self.source = source } }
    public struct Task: Codable, Sendable { public var title: String; public var due: Date?; public init(title: String, due: Date?) { self.title = title; self.due = due } }
    public struct Quote: Codable, Sendable { public var text: String; public var author: String; public var topic: String; public init(text: String, author: String, topic: String) { self.text = text; self.author = author; self.topic = topic } }

    public struct Countdown: Codable, Sendable, Hashable { public var title: String; public var date: Date; public init(title: String, date: Date) { self.title = title; self.date = date } }
    /// A widget the reader put together: a name, a look and up to four blocks in order.
    public struct Custom: Codable, Sendable, Hashable {
        public var name: String; public var style: String; public var blocks: [String]
        public init(name: String, style: String, blocks: [String]) { self.name = name; self.style = style; self.blocks = blocks }
        /// Blocks a custom widget can use, with their names in the app.
        public static let blocks: [(id: String, name: String)] = [("clock", "Clock"), ("weather", "Weather"), ("next", "Next event"), ("brief", "Brief"), ("needs", "Needs you"), ("news", "Top story"), ("tasks", "Tasks"), ("focus", "Focus"), ("countdown", "Countdown"), ("quote", "Quote")]
    }

    public var updated = Date()
    public var name = ""
    public var weather: Weather?
    public var events: [Event] = []
    public var brief: String?
    public var needsYou: [Item] = []
    public var needsCount = 0
    public var stories: [Story] = []
    public var tasks: [Task] = []
    public var quote: Quote?
    /// "flat" or "glass", chosen in Settings → Widgets.
    public var style = "glass"
    /// Days of the current month (1–31) that have an event, for the month calendar.
    public var eventDays: [Int] = []
    public var countdowns: [Countdown] = []
    /// Widgets the reader builds in Settings → Widgets; shown by the Custom 1–3 widgets.
    public var customs: [Custom] = []
    public init() {}

    public static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("everyday/widgets/snapshot.json")
    }

    /// Writes the snapshot where the widgets can read it. The developer copy (EVERYDAY_DEV=1) never overwrites it.
    public func write() throws {
        guard ProcessInfo.processInfo.environment["EVERYDAY_DEV"] != "1" else { return }
        let url = Self.fileURL
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// The first sentence or two of a briefing, short enough for a widget.
    public static func shortBrief(_ text: String, limit: Int = 170) -> String {
        BriefingSchedule.preview(text, limit: limit)
    }
}
