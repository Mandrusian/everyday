import WidgetKit
import SwiftUI

// MARK: - The snapshot the app writes (keep in step with WidgetSnapshot in EverydayCore)

struct Snap: Codable {
    struct Weather: Codable { var city: String; var temp: Double; var condition: String; var high: Double; var low: Double; var hours: [Hour] }
    struct Hour: Codable { var date: Date; var temp: Double }
    struct Event: Codable { var title: String; var start: Date; var allDay: Bool }
    struct Item: Codable { var who: String; var what: String }
    struct Story: Codable { var title: String; var source: String }
    struct Task: Codable { var title: String; var due: Date? }
    struct Quote: Codable { var text: String; var author: String; var topic: String }
    struct Countdown: Codable { var title: String; var date: Date }
    struct Custom: Codable { var name: String; var style: String; var blocks: [String] }
    var updated: Date
    var name: String
    var weather: Weather?
    var events: [Event]
    var brief: String?
    var needsYou: [Item]
    var needsCount: Int
    var stories: [Story]
    var tasks: [Task]
    var quote: Quote?
    var style: String?
    var eventDays: [Int]?
    var countdowns: [Countdown]?
    var customs: [Custom]?

    static let sample: Snap = {
        let cal = Calendar.current, now = Date()
        return Snap(updated: now, name: "Xavi",
            weather: Weather(city: "Cairns", temp: 27, condition: "Partly cloudy", high: 31, low: 22, hours: (1...5).map { Hour(date: now.addingTimeInterval(Double($0) * 10800), temp: 27 + Double($0 % 3)) }),
            events: [Event(title: "Roadmap sync", start: now.addingTimeInterval(3600), allDay: false), Event(title: "Lunch with Oscar", start: now.addingTimeInterval(4 * 3600), allDay: false), Event(title: "Pay invoice", start: now.addingTimeInterval(86400), allDay: true)],
            brief: "Oscar is waiting on a reply about Thursday. Sign the lease by Friday. 31° and clear in Cairns.",
            needsYou: [Item(who: "Oscar Fox", what: "Does Thursday 3pm still work?"), Item(who: "Greenfield Property", what: "Sign the lease by Friday")], needsCount: 2,
            stories: [Story(title: "A record year for home solar", source: "ABC News"), Story(title: "Open models close the gap", source: "The Decoder")],
            tasks: [Task(title: "Pay invoice #2041", due: now.addingTimeInterval(86400)), Task(title: "Book flights to Sydney", due: nil)],
            quote: Quote(text: "The impediment to action advances action. What stands in the way becomes the way.", author: "Marcus Aurelius", topic: "Stoicism"),
            style: "flat", eventDays: [cal.component(.day, from: now), min(28, cal.component(.day, from: now) + 1), 3, 17],
            countdowns: [Countdown(title: "Holidays", date: now.addingTimeInterval(86400 * 23))],
            customs: [Custom(name: "My morning", style: "flat", blocks: ["clock", "weather", "next"])])
    }()

    /// The app writes to ~/Library/Application Support/everyday/widgets/snapshot.json.
    /// The widget is sandboxed, so it reads the real home folder through a read-only exception.
    static func load() -> Snap? {
        guard let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir else { return nil }
        let base = URL(fileURLWithPath: String(cString: home)).appendingPathComponent("Library/Application Support")
        for folder in ["everyday", "everyday-dev"] {
            let url = base.appendingPathComponent("\(folder)/widgets/snapshot.json")
            if let d = try? Data(contentsOf: url) {
                let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
                if let s = try? dec.decode(Snap.self, from: d) { return s }
            }
        }
        return nil
    }
}

// MARK: - Timeline

struct Entry: TimelineEntry { let date: Date; let snap: Snap?; var placeholder = false }

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> Entry { Entry(date: Date(), snap: .sample, placeholder: true) }
    func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: Date(), snap: context.isPreview ? (Snap.load() ?? .sample) : Snap.load())) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let now = Date(), snap = Snap.load()
        // One entry a minute for the next hour keeps relative times fresh; the app also asks for a reload when it has news.
        let entries = (0..<60).map { Entry(date: now.addingTimeInterval(Double($0) * 60), snap: snap) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Look: flat paper, ink and clay, or Liquid Glass

enum Look: String { case flat, glass }

private struct LookKey: EnvironmentKey { static let defaultValue = Look.flat }
extension EnvironmentValues { var look: Look { get { self[LookKey.self] } set { self[LookKey.self] = newValue } } }

/// Colours for the current look. Glass sits over the desktop, so its text uses the system's vibrant primary and secondary.
struct Ink {
    let scheme: ColorScheme
    let look: Look
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)
    var paper: Color { scheme == .dark ? Color(red: 0.13, green: 0.12, blue: 0.11) : Color(red: 0.96, green: 0.94, blue: 0.89) }
    var text: Color { look == .glass ? .primary : (scheme == .dark ? Color(red: 0.94, green: 0.92, blue: 0.87) : Color(red: 0.13, green: 0.12, blue: 0.10)) }
    var muted: Color { look == .glass ? .secondary : (scheme == .dark ? Color(red: 0.62, green: 0.60, blue: 0.55) : Color(red: 0.42, green: 0.39, blue: 0.33)) }
    var faint: Color { muted.opacity(0.45) }
    var clay: Color { Ink.clay }
}

/// Reads the colour scheme and look from the environment so every view can say `ink.text`.
struct Inked<Content: View>: View {
    @Environment(\.colorScheme) var scheme
    @Environment(\.look) var look
    @ViewBuilder let content: (Ink) -> Content
    var body: some View { content(Ink(scheme: scheme, look: look)) }
}

struct WidgetBackground: View {
    let look: Look
    @Environment(\.colorScheme) var scheme
    var body: some View {
        if look == .glass { Color.clear }  // macOS draws real Liquid Glass behind a clear container
        else { Ink(scheme: scheme, look: .flat).paper }
    }
}

extension View {
    /// Flat paper or glass, from the app's setting unless a custom widget chose its own.
    func styled(_ snap: Snap?, override: String? = nil) -> some View {
        let look = Look(rawValue: override ?? snap?.style ?? "glass") ?? .glass
        return environment(\.look, look).containerBackground(for: .widget) { WidgetBackground(look: look) }
    }
}

struct Heading: View {
    let text: String
    var body: some View { Inked { ink in Text(text).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(ink.clay).lineLimit(1) } }
}

struct Wordmark: View {
    var size: CGFloat = 12
    var body: some View { Inked { ink in (Text("everyday").foregroundColor(ink.muted) + Text(".").foregroundColor(ink.clay)).font(.system(size: size, design: .serif)) } }
}

struct Empty: View {
    let text: String
    var body: some View {
        Inked { ink in
            VStack(alignment: .leading, spacing: 6) { Wordmark(); Spacer(); Text(text).font(.system(size: 12)).foregroundStyle(ink.muted) }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

func top<V: View>(_ v: V) -> some View { v.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading) }

func eventTime(_ e: Snap.Event) -> String {
    e.allDay ? "All day" : e.start.formatted(date: Calendar.current.isDateInToday(e.start) ? .omitted : .abbreviated, time: .shortened)
}

func upcoming(_ entry: Entry) -> [Snap.Event] {
    (entry.snap?.events ?? []).filter { $0.allDay ? $0.start > entry.date.addingTimeInterval(-86400) : $0.start > entry.date.addingTimeInterval(-900) }
}

// MARK: - Clock

struct ClockView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            top(VStack(alignment: .leading, spacing: 2) {
                Text(entry.date.formatted(.dateTime.weekday(.wide))).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.clay)
                Spacer(minLength: 0)
                Text(entry.date, style: .time).font(.system(size: family == .systemSmall ? 44 : 60, weight: .light, design: .serif)).foregroundStyle(ink.text).minimumScaleFactor(0.5).lineLimit(1)
                Text(entry.date.formatted(.dateTime.day().month(.wide))).font(.system(size: 13)).foregroundStyle(ink.muted)
                if family != .systemSmall, let e = upcoming(entry).first {
                    Text("\(e.title), \(eventTime(e))").font(.system(size: 12)).foregroundStyle(ink.text).lineLimit(1).padding(.top, 6)
                }
            })
        }
    }
}

// MARK: - Weather

struct WeatherView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            if let w = entry.snap?.weather {
                top(VStack(alignment: .leading, spacing: 3) {
                    Heading(text: w.city)
                    Spacer(minLength: 0)
                    Text("\(Int(w.temp.rounded()))°").font(.system(size: 48, weight: .light, design: .serif)).foregroundStyle(ink.text)
                    Text(w.condition).font(.system(size: 13)).foregroundStyle(ink.text).lineLimit(1)
                    Text("H \(Int(w.high.rounded()))°  L \(Int(w.low.rounded()))°").font(.system(size: 11.5)).foregroundStyle(ink.muted)
                    if family != .systemSmall {
                        HStack {
                            ForEach(Array(w.hours.prefix(5).enumerated()), id: \.offset) { _, h in
                                VStack(spacing: 2) {
                                    Text(h.date.formatted(.dateTime.hour())).font(.system(size: 10.5)).foregroundStyle(ink.muted)
                                    Text("\(Int(h.temp.rounded()))°").font(.system(size: 13, weight: .medium)).foregroundStyle(ink.text)
                                }.frame(maxWidth: .infinity)
                            }
                        }.padding(.top, 6)
                    }
                })
            } else { Empty(text: "Open everyday. to load the weather.") }
        }
    }
}

// MARK: - Up next (agenda)

struct AgendaList: View {
    let events: [Snap.Event]
    let limit: Int
    var body: some View {
        Inked { ink in
            VStack(alignment: .leading, spacing: 7) {
                if events.isEmpty { Text("Nothing on the calendar.").font(.system(size: 12)).foregroundStyle(ink.muted) }
                ForEach(Array(events.prefix(limit).enumerated()), id: \.offset) { _, e in
                    HStack(alignment: .top, spacing: 7) {
                        Capsule().fill(ink.clay).frame(width: 3, height: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink.text).lineLimit(1)
                            Text(eventTime(e)).font(.system(size: 11)).foregroundStyle(ink.muted)
                        }
                    }
                }
            }
        }
    }
}

struct AgendaView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            top(VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(entry.date.formatted(.dateTime.weekday(.wide))).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.clay)
                    Text(entry.date.formatted(.dateTime.day())).font(.system(size: 32, weight: .light, design: .serif)).foregroundStyle(ink.text)
                }
                AgendaList(events: upcoming(entry), limit: family == .systemLarge ? 8 : family == .systemSmall ? 2 : 3)
                Spacer(minLength: 0)
            })
        }
    }
}

// MARK: - Month (like the system Calendar widget)

struct MonthGrid: View {
    let date: Date
    let eventDays: Set<Int>
    var compact = false
    var body: some View {
        Inked { ink in
            let cal = Calendar.current
            let start = cal.date(from: cal.dateComponents([.year, .month], from: date))!
            let days = cal.range(of: .day, in: .month, for: start)!.count
            let lead = (cal.component(.weekday, from: start) - cal.firstWeekday + 7) % 7
            let today = cal.component(.day, from: date)
            let symbols = Array(cal.veryShortWeekdaySymbols[(cal.firstWeekday - 1)...] + cal.veryShortWeekdaySymbols[..<(cal.firstWeekday - 1)])
            let cells: [Int?] = Array(repeating: nil, count: lead) + (1...days).map { Optional($0) }
            let rows = stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) + Array(repeating: nil, count: max(0, $0 + 7 - cells.count)) }
            let size: CGFloat = compact ? 10.5 : 11.5
            VStack(alignment: .leading, spacing: compact ? 3 : 5) {
                Text(date.formatted(.dateTime.month(.wide))).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink.clay)
                Grid(horizontalSpacing: 0, verticalSpacing: compact ? 1 : 3) {
                    GridRow {
                        ForEach(0..<7, id: \.self) { i in
                            Text(symbols[i]).font(.system(size: size - 1.5, weight: .semibold)).foregroundStyle(ink.muted).frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(0..<rows.count, id: \.self) { r in
                        GridRow {
                            ForEach(0..<7, id: \.self) { c in
                                if let d = rows[r][c] {
                                    let weekend = cal.isDateInWeekend(cal.date(byAdding: .day, value: d - 1, to: start)!)
                                    VStack(spacing: 0) {
                                        Text("\(d)").font(.system(size: size, weight: d == today ? .bold : .medium))
                                            .foregroundStyle(d == today ? Color.white : (weekend ? ink.muted : ink.text))
                                            .frame(width: size * 1.9, height: size * 1.9)
                                            .background(Circle().fill(d == today ? ink.clay : .clear))
                                        Circle().fill(eventDays.contains(d) && d != today ? ink.clay : .clear).frame(width: 3, height: 3)
                                    }.frame(maxWidth: .infinity)
                                } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct MonthView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            let days = Set(entry.snap?.eventDays ?? [])
            switch family {
            case .systemMedium:
                HStack(alignment: .top, spacing: 14) {
                    top(VStack(alignment: .leading, spacing: 8) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.date.formatted(.dateTime.weekday(.wide))).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.clay)
                            Text(entry.date.formatted(.dateTime.day())).font(.system(size: 30, weight: .light, design: .serif)).foregroundStyle(ink.text)
                        }
                        AgendaList(events: upcoming(entry), limit: 2)
                    })
                    MonthGrid(date: entry.date, eventDays: days, compact: true).frame(maxWidth: .infinity)
                }
            case .systemLarge:
                top(VStack(alignment: .leading, spacing: 14) {
                    MonthGrid(date: entry.date, eventDays: days)
                    Rectangle().fill(ink.faint).frame(height: 0.5)
                    AgendaList(events: upcoming(entry), limit: 4)
                    Spacer(minLength: 0)
                })
            default:
                MonthGrid(date: entry.date, eventDays: days, compact: true)
            }
        }
    }
}

// MARK: - Brief

struct BriefView: View {
    let entry: Entry
    var body: some View {
        Inked { ink in
            top(VStack(alignment: .leading, spacing: 6) {
                HStack { Heading(text: "Your day"); Spacer(); Wordmark(size: 11) }
                if let b = entry.snap?.brief, !b.isEmpty {
                    Text(b).font(.system(size: 14.5, design: .serif)).foregroundStyle(ink.text).lineSpacing(2).minimumScaleFactor(0.8)
                } else { Text("Your briefing appears here after it's written.").font(.system(size: 12)).foregroundStyle(ink.muted) }
                Spacer(minLength: 0)
            })
        }
    }
}

// MARK: - Quote of the day

struct QuoteView: View {
    let entry: Entry
    var body: some View {
        Inked { ink in
            if let q = entry.snap?.quote {
                top(VStack(alignment: .leading, spacing: 6) {
                    Heading(text: q.topic)
                    Text("“\(q.text)”").font(.system(size: 15, design: .serif).italic()).foregroundStyle(ink.text).minimumScaleFactor(0.7)
                    Spacer(minLength: 0)
                    Text(q.author).font(.system(size: 12)).foregroundStyle(ink.muted)
                })
            } else { Empty(text: "Pick a topic in Settings → Widgets.") }
        }
    }
}

// MARK: - Needs you

struct NeedsYouView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            let s = entry.snap, n = s?.needsCount ?? 0
            top(VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(n)").font(.system(size: 34, weight: .light, design: .serif)).foregroundStyle(n > 0 ? ink.clay : ink.text)
                    Text(n == 1 ? "needs you" : "need you").font(.system(size: 12)).foregroundStyle(ink.muted)
                    Spacer()
                }
                ForEach(Array((s?.needsYou ?? []).prefix(family == .systemSmall ? 1 : 3).enumerated()), id: \.offset) { _, i in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(i.who).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink.text).lineLimit(1)
                        Text(i.what).font(.system(size: 11.5)).foregroundStyle(ink.muted).lineLimit(family == .systemSmall ? 2 : 1)
                    }
                }
                if n == 0 { Text("You're all caught up.").font(.system(size: 12)).foregroundStyle(ink.muted) }
                Spacer(minLength: 0)
            })
        }
    }
}

// MARK: - Top news

struct NewsView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            top(VStack(alignment: .leading, spacing: 9) {
                Heading(text: "Top news")
                let list = entry.snap?.stories ?? []
                if list.isEmpty { Text("Stories appear after the news refreshes.").font(.system(size: 12)).foregroundStyle(ink.muted) }
                ForEach(Array(list.prefix(family == .systemLarge ? 6 : family == .systemSmall ? 2 : 3).enumerated()), id: \.offset) { _, st in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(st.title).font(.system(size: 13.5, design: .serif)).foregroundStyle(ink.text).lineLimit(2)
                        Text(st.source).font(.system(size: 10.5)).foregroundStyle(ink.muted)
                    }
                }
                Spacer(minLength: 0)
            })
        }
    }
}

// MARK: - Tasks

struct TaskRows: View {
    let tasks: [Snap.Task]
    let limit: Int
    var body: some View {
        Inked { ink in
            VStack(alignment: .leading, spacing: 7) {
                if tasks.isEmpty { Text("Nothing to do.").font(.system(size: 12)).foregroundStyle(ink.muted) }
                ForEach(Array(tasks.prefix(limit).enumerated()), id: \.offset) { _, t in
                    HStack(spacing: 7) {
                        Circle().stroke(ink.muted, lineWidth: 1).frame(width: 11, height: 11)
                        Text(t.title).font(.system(size: 12.5)).foregroundStyle(ink.text).lineLimit(1)
                        Spacer(minLength: 4)
                        if let d = t.due { Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10.5)).foregroundStyle(d < Date() ? ink.clay : ink.muted) }
                    }
                }
            }
        }
    }
}

struct TasksView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        top(VStack(alignment: .leading, spacing: 8) {
            Heading(text: "Tasks")
            TaskRows(tasks: entry.snap?.tasks ?? [], limit: family == .systemLarge ? 10 : 4)
            Spacer(minLength: 0)
        })
    }
}

// MARK: - Focus: the one task that matters now

struct FocusView: View {
    let entry: Entry
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            if let t = entry.snap?.tasks.first {
                top(VStack(alignment: .leading, spacing: 4) {
                    Heading(text: "Focus")
                    Spacer(minLength: 0)
                    Text(t.title).font(.system(size: family == .systemSmall ? 19 : 23, design: .serif)).foregroundStyle(ink.text).lineLimit(3).minimumScaleFactor(0.7)
                    if let d = t.due { Text("Due \(d.formatted(.relative(presentation: .named)))").font(.system(size: 12)).foregroundStyle(d < entry.date ? ink.clay : ink.muted) }
                    let more = (entry.snap?.tasks.count ?? 1) - 1
                    if more > 0 { Text("\(more) more after this").font(.system(size: 11)).foregroundStyle(ink.muted) }
                })
            } else { Empty(text: "No open tasks. Enjoy it.") }
        }
    }
}

// MARK: - Countdown

struct CountdownView: View {
    let entry: Entry
    var body: some View {
        Inked { ink in
            if let c = entry.snap?.countdowns?.first {
                let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date), to: Calendar.current.startOfDay(for: c.date)).day ?? 0)
                top(VStack(alignment: .leading, spacing: 2) {
                    Heading(text: c.title)
                    Spacer(minLength: 0)
                    Text(days == 0 ? "Today" : "\(days)").font(.system(size: 52, weight: .light, design: .serif)).foregroundStyle(ink.text).minimumScaleFactor(0.5).lineLimit(1)
                    if days > 0 { Text(days == 1 ? "day to go" : "days to go").font(.system(size: 13)).foregroundStyle(ink.muted) }
                    Text(c.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))).font(.system(size: 11.5)).foregroundStyle(ink.muted)
                })
            } else { Empty(text: "Add a countdown in Settings → Widgets.") }
        }
    }
}

// MARK: - Today (large): the day on one card

struct TodayView: View {
    let entry: Entry
    var body: some View {
        Inked { ink in
            let s = entry.snap
            top(VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(entry.date.formatted(.dateTime.weekday(.wide))).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(ink.clay)
                        Text(entry.date.formatted(.dateTime.day().month(.wide))).font(.system(size: 26, weight: .light, design: .serif)).foregroundStyle(ink.text)
                    }
                    Spacer()
                    if let w = s?.weather {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(w.temp.rounded()))°").font(.system(size: 26, weight: .light, design: .serif)).foregroundStyle(ink.text)
                            Text(w.condition).font(.system(size: 11)).foregroundStyle(ink.muted).lineLimit(1)
                        }
                    }
                }
                if let b = s?.brief, !b.isEmpty { Text(b).font(.system(size: 13.5, design: .serif)).foregroundStyle(ink.text).lineSpacing(2).lineLimit(4) }
                Rectangle().fill(ink.faint).frame(height: 0.5)
                AgendaList(events: upcoming(entry), limit: 3)
                Rectangle().fill(ink.faint).frame(height: 0.5)
                HStack(alignment: .top) {
                    TaskRows(tasks: s?.tasks ?? [], limit: 3)
                    if let n = s?.needsCount, n > 0 {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(n)").font(.system(size: 22, weight: .light, design: .serif)).foregroundStyle(ink.clay)
                            Text(n == 1 ? "needs you" : "need you").font(.system(size: 10.5)).foregroundStyle(ink.muted)
                        }.padding(.leading, 8)
                    }
                }
                Spacer(minLength: 0)
            })
        }
    }
}

// MARK: - Custom: blocks the reader picked in the app

struct CustomView: View {
    let entry: Entry
    let slot: Int
    @Environment(\.widgetFamily) var family
    var body: some View {
        Inked { ink in
            if let c = entry.snap?.customs?[safe: slot], !c.blocks.isEmpty {
                let blocks = Array(c.blocks.prefix(family == .systemLarge ? 6 : family == .systemMedium ? 3 : 2))
                top(VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { i, b in
                        if i > 0 { Rectangle().fill(ink.faint).frame(height: 0.5) }
                        block(b, ink)
                    }
                    Spacer(minLength: 0)
                })
            } else { Empty(text: "Build this widget in Settings → Widgets.") }
        }
    }

    @ViewBuilder func block(_ id: String, _ ink: Ink) -> some View {
        let s = entry.snap
        switch id {
        case "clock":
            HStack(alignment: .firstTextBaseline) {
                Text(entry.date, style: .time).font(.system(size: 28, weight: .light, design: .serif)).foregroundStyle(ink.text).lineLimit(1).minimumScaleFactor(0.6)
                Spacer(minLength: 4)
                Text(entry.date.formatted(.dateTime.weekday(.abbreviated).day())).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.clay)
            }
        case "weather":
            if let w = s?.weather {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(Int(w.temp.rounded()))°").font(.system(size: 22, weight: .light, design: .serif)).foregroundStyle(ink.text)
                    Text("\(w.condition) in \(w.city)").font(.system(size: 12)).foregroundStyle(ink.muted).lineLimit(1)
                }
            }
        case "next": AgendaList(events: upcoming(entry), limit: family == .systemLarge ? 3 : 1)
        case "brief": if let b = s?.brief { Text(b).font(.system(size: 13, design: .serif)).foregroundStyle(ink.text).lineLimit(family == .systemLarge ? 5 : 3) }
        case "needs":
            let n = s?.needsCount ?? 0
            VStack(alignment: .leading, spacing: 1) {
                Text(n == 0 ? "All caught up" : "\(n) \(n == 1 ? "needs" : "need") you").font(.system(size: 13, weight: .semibold)).foregroundStyle(n > 0 ? ink.clay : ink.muted)
                if let i = s?.needsYou.first { Text("\(i.who): \(i.what)").font(.system(size: 11.5)).foregroundStyle(ink.muted).lineLimit(1) }
            }
        case "news":
            if let st = s?.stories.first {
                VStack(alignment: .leading, spacing: 1) {
                    Text(st.title).font(.system(size: 13, design: .serif)).foregroundStyle(ink.text).lineLimit(2)
                    Text(st.source).font(.system(size: 10.5)).foregroundStyle(ink.muted)
                }
            }
        case "tasks": TaskRows(tasks: s?.tasks ?? [], limit: family == .systemLarge ? 4 : 2)
        case "focus":
            if let t = s?.tasks.first { Text(t.title).font(.system(size: 16, design: .serif)).foregroundStyle(ink.text).lineLimit(2) }
        case "countdown":
            if let c = s?.countdowns?.first {
                let days = max(0, Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: entry.date), to: Calendar.current.startOfDay(for: c.date)).day ?? 0)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(days)").font(.system(size: 22, weight: .light, design: .serif)).foregroundStyle(ink.text)
                    Text("days to \(c.title)").font(.system(size: 12)).foregroundStyle(ink.muted).lineLimit(1)
                }
            }
        case "quote":
            if let q = s?.quote { Text("“\(q.text)”").font(.system(size: 12.5, design: .serif).italic()).foregroundStyle(ink.text).lineLimit(3) }
        default: EmptyView()
        }
    }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }

// MARK: - Widgets

func config<V: View>(_ kind: String, _ name: String, _ about: String, _ families: [WidgetFamily], override: ((Snap?) -> String?)? = nil, _ view: @escaping (Entry) -> V) -> some WidgetConfiguration {
    StaticConfiguration(kind: kind, provider: Provider()) { e in view(e).styled(e.snap, override: override?(e.snap)) }
        .configurationDisplayName(name).description(about).supportedFamilies(families)
}

struct ClockWidget: Widget { var body: some WidgetConfiguration { config("clock", "Clock", "The time and date, with your next event.", [.systemSmall, .systemMedium]) { ClockView(entry: $0) } } }
struct WeatherWidget: Widget { var body: some WidgetConfiguration { config("weather", "Weather", "Now and the next few hours for your city.", [.systemSmall, .systemMedium]) { WeatherView(entry: $0) } } }
struct CalendarWidget: Widget { var body: some WidgetConfiguration { config("calendar", "Up next", "Today's date and what's coming up.", [.systemSmall, .systemMedium, .systemLarge]) { AgendaView(entry: $0) } } }
struct MonthWidget: Widget { var body: some WidgetConfiguration { config("month", "Calendar", "The month at a glance, with today and days that have events.", [.systemSmall, .systemMedium, .systemLarge]) { MonthView(entry: $0) } } }
struct BriefWidget: Widget { var body: some WidgetConfiguration { config("brief", "Brief", "Your briefing in a couple of sentences.", [.systemMedium, .systemLarge]) { BriefView(entry: $0) } } }
struct QuoteWidget: Widget { var body: some WidgetConfiguration { config("quote", "Quote of the day", "A daily quote on a topic you choose in Settings → Widgets.", [.systemSmall, .systemMedium]) { QuoteView(entry: $0) } } }
struct NeedsYouWidget: Widget { var body: some WidgetConfiguration { config("needsyou", "Needs you", "Mail waiting on you.", [.systemSmall, .systemMedium]) { NeedsYouView(entry: $0) } } }
struct NewsWidget: Widget { var body: some WidgetConfiguration { config("news", "Top news", "The stories that matter to you.", [.systemSmall, .systemMedium, .systemLarge]) { NewsView(entry: $0) } } }
struct TasksWidget: Widget { var body: some WidgetConfiguration { config("tasks", "Tasks", "What's open and due.", [.systemSmall, .systemMedium, .systemLarge]) { TasksView(entry: $0) } } }
struct FocusWidget: Widget { var body: some WidgetConfiguration { config("focus", "Focus", "The one task to do next.", [.systemSmall, .systemMedium]) { FocusView(entry: $0) } } }
struct CountdownWidget: Widget { var body: some WidgetConfiguration { config("countdown", "Countdown", "Days until something you're looking forward to.", [.systemSmall]) { CountdownView(entry: $0) } } }
struct TodayWidget: Widget { var body: some WidgetConfiguration { config("today", "Today", "Your day on one card: weather, brief, calendar and tasks.", [.systemLarge]) { TodayView(entry: $0) } } }
struct Custom1Widget: Widget { var body: some WidgetConfiguration { config("custom1", "Custom 1", "A widget you build in Settings → Widgets.", [.systemSmall, .systemMedium, .systemLarge], override: { $0?.customs?[safe: 0]?.style }) { CustomView(entry: $0, slot: 0) } } }
struct Custom2Widget: Widget { var body: some WidgetConfiguration { config("custom2", "Custom 2", "A widget you build in Settings → Widgets.", [.systemSmall, .systemMedium, .systemLarge], override: { $0?.customs?[safe: 1]?.style }) { CustomView(entry: $0, slot: 1) } } }
struct Custom3Widget: Widget { var body: some WidgetConfiguration { config("custom3", "Custom 3", "A widget you build in Settings → Widgets.", [.systemSmall, .systemMedium, .systemLarge], override: { $0?.customs?[safe: 2]?.style }) { CustomView(entry: $0, slot: 2) } } }

@main
struct EverydayWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClockWidget(); WeatherWidget(); MonthWidget(); CalendarWidget(); TodayWidget(); BriefWidget(); NeedsYouWidget(); TasksWidget(); FocusWidget()
        MoreWidgets().body
    }
}

/// A bundle holds at most ten widgets per builder, so the rest live here.
struct MoreWidgets: WidgetBundle {
    var body: some Widget { CountdownWidget(); NewsWidget(); QuoteWidget(); Custom1Widget(); Custom2Widget(); Custom3Widget() }
}
