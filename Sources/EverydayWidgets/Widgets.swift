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

    static let sample = Snap(updated: Date(), name: "Xavi",
        weather: Weather(city: "Cairns", temp: 27, condition: "Partly cloudy", high: 31, low: 22, hours: (1...4).map { Hour(date: Date().addingTimeInterval(Double($0) * 10800), temp: 27 + Double($0 % 3)) }),
        events: [Event(title: "Roadmap sync", start: Date().addingTimeInterval(3600), allDay: false), Event(title: "Pay invoice", start: Date().addingTimeInterval(86400), allDay: true)],
        brief: "Oscar is waiting on a reply about Thursday. Sign the lease by Friday. 31° and clear in Cairns.",
        needsYou: [Item(who: "Oscar Fox", what: "Does Thursday 3pm still work?"), Item(who: "Greenfield Property", what: "Sign the lease by Friday")], needsCount: 2,
        stories: [Story(title: "A record year for home solar", source: "ABC News"), Story(title: "Open models close the gap", source: "The Decoder")],
        tasks: [Task(title: "Pay invoice #2041", due: Date().addingTimeInterval(86400))],
        quote: Quote(text: "The impediment to action advances action. What stands in the way becomes the way.", author: "Marcus Aurelius", topic: "Stoicism"))

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

// MARK: - Look: warm paper, ink and clay

enum Ink {
    static func paper(_ s: ColorScheme) -> Color { s == .dark ? Color(red: 0.11, green: 0.10, blue: 0.09) : Color(red: 0.96, green: 0.93, blue: 0.87) }
    static func text(_ s: ColorScheme) -> Color { s == .dark ? Color(red: 0.93, green: 0.91, blue: 0.85) : Color(red: 0.14, green: 0.13, blue: 0.10) }
    static func muted(_ s: ColorScheme) -> Color { s == .dark ? Color(red: 0.64, green: 0.62, blue: 0.57) : Color(red: 0.36, green: 0.33, blue: 0.27) }
    static let clay = Color(red: 0.85, green: 0.47, blue: 0.34)
}

struct PaperBackground: View {
    @Environment(\.colorScheme) var scheme
    var body: some View {
        ZStack {
            Ink.paper(scheme)
            // A faint fibre texture drawn with a few hundred short strokes, seeded so it never flickers.
            Canvas { ctx, size in
                var seed: UInt64 = 42
                func r() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
                for _ in 0..<260 {
                    let x = r() * size.width, y = r() * size.height, l = 4 + r() * 10, a = (r() - 0.5) * 0.6
                    var p = Path(); p.move(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x + cos(a) * l, y: y + sin(a) * l))
                    ctx.stroke(p, with: .color((scheme == .dark ? Color.white : Color(red: 0.4, green: 0.3, blue: 0.15)).opacity(0.05)), lineWidth: 0.6)
                }
            }
        }
    }
}

struct Label2: View {
    let text: String
    @Environment(\.colorScheme) var scheme
    var body: some View { Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.1).foregroundStyle(Ink.clay) }
}

struct Wordmark: View {
    @Environment(\.colorScheme) var scheme
    var size: CGFloat = 12
    var body: some View { (Text("everyday").foregroundColor(Ink.muted(scheme)) + Text(".").foregroundColor(Ink.clay)).font(.system(size: size, design: .serif)) }
}

extension View {
    func paperWidget() -> some View { containerBackground(for: .widget) { PaperBackground() } }
}

func empty(_ text: String, _ scheme: ColorScheme) -> some View {
    VStack(alignment: .leading, spacing: 6) { Wordmark(); Spacer(); Text(text).font(.system(size: 12)).foregroundStyle(Ink.muted(scheme)) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
}

// MARK: - Clock

struct ClockView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    @Environment(\.widgetFamily) var family
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Wordmark()
            Spacer(minLength: 0)
            Text(entry.date, style: .time).font(.system(size: family == .systemSmall ? 40 : 54, weight: .regular, design: .serif)).foregroundStyle(Ink.text(scheme)).minimumScaleFactor(0.6).lineLimit(1)
            Text(entry.date.formatted(.dateTime.weekday(.wide).day().month(.wide))).font(.system(size: 13)).foregroundStyle(Ink.muted(scheme))
            if family != .systemSmall, let e = entry.snap?.events.first {
                Text("Next: \(e.title), \(e.allDay ? "all day" : e.start.formatted(date: .omitted, time: .shortened))").font(.system(size: 12)).foregroundStyle(Ink.clay).lineLimit(1).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Weather

struct WeatherView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    @Environment(\.widgetFamily) var family
    var body: some View {
        if let w = entry.snap?.weather {
            VStack(alignment: .leading, spacing: 4) {
                HStack { Label2(text: w.city); Spacer(); Text("H \(Int(w.high.rounded()))° L \(Int(w.low.rounded()))°").font(.system(size: 11)).foregroundStyle(Ink.muted(scheme)) }
                Spacer(minLength: 0)
                Text("\(Int(w.temp.rounded()))°").font(.system(size: 46, design: .serif)).foregroundStyle(Ink.text(scheme))
                Text(w.condition).font(.system(size: 13)).foregroundStyle(Ink.muted(scheme)).lineLimit(1)
                if family != .systemSmall {
                    HStack {
                        ForEach(Array(w.hours.prefix(5).enumerated()), id: \.offset) { _, h in
                            VStack(spacing: 2) { Text(h.date.formatted(.dateTime.hour())).font(.system(size: 10)).foregroundStyle(Ink.muted(scheme)); Text("\(Int(h.temp.rounded()))°").font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.text(scheme)) }.frame(maxWidth: .infinity)
                        }
                    }.padding(.top, 6)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else { empty("Open everyday. to load the weather.", scheme) }
    }
}

// MARK: - Calendar

struct CalendarView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    @Environment(\.widgetFamily) var family
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.date.formatted(.dateTime.day())).font(.system(size: 30, design: .serif)).foregroundStyle(Ink.text(scheme))
                Text(entry.date.formatted(.dateTime.weekday(.wide))).font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.clay)
                Spacer()
            }
            let events = (entry.snap?.events ?? []).filter { $0.allDay || $0.start > entry.date.addingTimeInterval(-1800) }
            if events.isEmpty { Text("Nothing on the calendar.").font(.system(size: 12)).foregroundStyle(Ink.muted(scheme)) }
            ForEach(Array(events.prefix(family == .systemLarge ? 8 : family == .systemSmall ? 2 : 3).enumerated()), id: \.offset) { _, e in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Ink.clay).frame(width: 2, height: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Ink.text(scheme)).lineLimit(1)
                        Text(e.allDay ? "All day" : e.start.formatted(date: Calendar.current.isDateInToday(e.start) ? .omitted : .abbreviated, time: .shortened)).font(.system(size: 11)).foregroundStyle(Ink.muted(scheme))
                    }
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Brief

struct BriefView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Label2(text: "Your day"); Spacer(); Wordmark(size: 11) }
            if let b = entry.snap?.brief, !b.isEmpty {
                Text(b).font(.system(size: 14, design: .serif)).foregroundStyle(Ink.text(scheme)).lineSpacing(2).minimumScaleFactor(0.8)
            } else { Text("Your briefing appears here after it's written.").font(.system(size: 12)).foregroundStyle(Ink.muted(scheme)) }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Quote of the day

struct QuoteView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    var body: some View {
        if let q = entry.snap?.quote {
            VStack(alignment: .leading, spacing: 6) {
                Label2(text: q.topic)
                Text("“\(q.text)”").font(.system(size: 15, design: .serif).italic()).foregroundStyle(Ink.text(scheme)).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Text(q.author).font(.system(size: 12)).foregroundStyle(Ink.muted(scheme))
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else { empty("Pick a topic in Settings → Widgets.", scheme) }
    }
}

// MARK: - Needs you

struct NeedsYouView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    @Environment(\.widgetFamily) var family
    var body: some View {
        let s = entry.snap
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(s?.needsCount ?? 0)").font(.system(size: 34, design: .serif)).foregroundStyle(Ink.text(scheme))
                Text((s?.needsCount ?? 0) == 1 ? "thing needs you" : "things need you").font(.system(size: 12)).foregroundStyle(Ink.muted(scheme))
                Spacer()
            }
            ForEach(Array((s?.needsYou ?? []).prefix(family == .systemSmall ? 1 : 3).enumerated()), id: \.offset) { _, i in
                VStack(alignment: .leading, spacing: 0) {
                    Text(i.who).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Ink.text(scheme)).lineLimit(1)
                    Text(i.what).font(.system(size: 11.5)).foregroundStyle(Ink.muted(scheme)).lineLimit(1)
                }
            }
            if (s?.needsCount ?? 0) == 0 { Text("You're all caught up.").font(.system(size: 12)).foregroundStyle(Ink.muted(scheme)) }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Top stories

struct NewsView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    @Environment(\.widgetFamily) var family
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label2(text: "Top news")
            let list = entry.snap?.stories ?? []
            if list.isEmpty { Text("Stories appear after the news refreshes.").font(.system(size: 12)).foregroundStyle(Ink.muted(scheme)) }
            ForEach(Array(list.prefix(family == .systemLarge ? 6 : family == .systemSmall ? 2 : 3).enumerated()), id: \.offset) { _, st in
                VStack(alignment: .leading, spacing: 1) {
                    Text(st.title).font(.system(size: 13.5, design: .serif)).foregroundStyle(Ink.text(scheme)).lineLimit(2)
                    Text(st.source).font(.system(size: 10.5)).foregroundStyle(Ink.muted(scheme))
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tasks

struct TasksView: View {
    let entry: Entry
    @Environment(\.colorScheme) var scheme
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label2(text: "Tasks")
            let list = entry.snap?.tasks ?? []
            if list.isEmpty { Text("Nothing to do.").font(.system(size: 12)).foregroundStyle(Ink.muted(scheme)) }
            ForEach(Array(list.prefix(4).enumerated()), id: \.offset) { _, t in
                HStack(spacing: 7) {
                    Circle().stroke(Ink.muted(scheme), lineWidth: 1).frame(width: 11, height: 11)
                    Text(t.title).font(.system(size: 12.5)).foregroundStyle(Ink.text(scheme)).lineLimit(1)
                    Spacer(minLength: 4)
                    if let d = t.due { Text(d.formatted(.dateTime.weekday(.abbreviated))).font(.system(size: 10.5)).foregroundStyle(d < Date() ? Ink.clay : Ink.muted(scheme)) }
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Widgets

struct ClockWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "clock", provider: Provider()) { ClockView(entry: $0).paperWidget() }
            .configurationDisplayName("Clock").description("The time and date on warm paper, with your next event.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct WeatherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "weather", provider: Provider()) { WeatherView(entry: $0).paperWidget() }
            .configurationDisplayName("Weather").description("Now and the next few hours for your city.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "calendar", provider: Provider()) { CalendarView(entry: $0).paperWidget() }
            .configurationDisplayName("Up next").description("Today's date and what's coming up.").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct BriefWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "brief", provider: Provider()) { BriefView(entry: $0).paperWidget() }
            .configurationDisplayName("Brief").description("Your briefing in a couple of sentences.").supportedFamilies([.systemMedium, .systemLarge])
    }
}
struct QuoteWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "quote", provider: Provider()) { QuoteView(entry: $0).paperWidget() }
            .configurationDisplayName("Quote of the day").description("A daily quote on a topic you choose in Settings → Widgets.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct NeedsYouWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "needsyou", provider: Provider()) { NeedsYouView(entry: $0).paperWidget() }
            .configurationDisplayName("Needs you").description("Mail waiting on you.").supportedFamilies([.systemSmall, .systemMedium])
    }
}
struct NewsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "news", provider: Provider()) { NewsView(entry: $0).paperWidget() }
            .configurationDisplayName("Top news").description("The stories that matter to you.").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct TasksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "tasks", provider: Provider()) { TasksView(entry: $0).paperWidget() }
            .configurationDisplayName("Tasks").description("What's open and due.").supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct EverydayWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClockWidget(); WeatherWidget(); CalendarWidget(); BriefWidget(); QuoteWidget(); NeedsYouWidget(); NewsWidget(); TasksWidget()
    }
}
