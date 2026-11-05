import SwiftUI
import EverydayCore

struct TodayView: View {
    @Environment(AppModel.self) private var model
    @Local private var customizing = false
    @Local private var search = ""

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning" : h < 18 ? "Good afternoon" : "Good evening"
    }
    private var dateLine: String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"
        return "\(f.string(from: Date())), \(model.weatherNow?.city ?? model.weather.city)"
    }
    func visible(_ id: String) -> Bool { !model.dashboardHidden.contains(id) }

    /// One entry per thing that needs the user: a conversation, or a bundle of repeated automated mail.
    enum Att: Identifiable {
        case row(MailRow), bundle(MailBundle)
        var id: String { switch self { case .row(let r): return r.id; case .bundle(let b): return "b:" + b.id } }
        var priority: Int { switch self { case .row(let r): return r.triage?.priority ?? 0; case .bundle(let b): return b.priority } }
    }

    private var attention: [Att] {
        let rs = model.rows.filter(MailService.isAttention)
        let bs = MailBundler.bundles(from: rs, minCount: 2)
        let inB = Set(bs.flatMap { $0.rows.map(\.id) })
        let all: [Att] = rs.filter { !inB.contains($0.id) }.map { .row($0) } + bs.map { .bundle($0) }
        return Array(all.sorted { $0.priority > $1.priority }.prefix(4))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Text("Today").font(.ui(18, .semibold))
                Text(dateLine).font(.ui(15)).foregroundStyle(Palette.text2)
                Spacer()
                if model.refreshingNews || model.syncingMail { ProgressView().controlSize(.small) }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.text3)
                    TextField("Search mail, news, tasks", text: $search).accessibilityLabel("Search mail, news and tasks").textFieldStyle(.plain).font(.ui(14.5))
                        .onSubmit { runSearch() }
                }.padding(.horizontal, 10).frame(width: 240, height: 30).background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised))
                Button("Customize") { customizing.toggle() }.buttonStyle(QuietButtonStyle(compact: true))
                    .popover(isPresented: $customizing, arrowEdge: .bottom) { customizePopover }
                Button { Task { await model.refreshEverything() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(QuietButtonStyle(compact: true)).help("Refresh everything (⌘R)").accessibilityLabel("Refresh")
            }.padding(.horizontal, 24).frame(height: 52).overlay(alignment: .bottom) { Hairline() }

            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    VStack(alignment: .leading, spacing: 4) {
                        (Text("\(greeting), ").font(.serif(34, .regular)) + Text("\(model.userName).").font(.serifItalic(34)))
                            .foregroundStyle(Palette.text)
                        Text(subline).font(.ui(15.5)).foregroundStyle(Palette.text2)
                    }
                    HStack(alignment: .top, spacing: 32) {
                        if visible("briefing") { briefingSection.frame(maxWidth: .infinity, alignment: .topLeading) }
                        if visible("weather") || visible("calendar") {
                            VStack(alignment: .leading, spacing: 20) {
                                if visible("weather") { weatherSection }
                                if visible("calendar") { calendarSection }
                            }.frame(width: 290, alignment: .topLeading).padding(.leading, 32).overlay(alignment: .leading) { Hairline(vertical: true) }
                        }
                    }
                    let bottom = ["inbox", "news", "tasks"].filter(visible)
                    if !bottom.isEmpty {
                        Hairline()
                        HStack(alignment: .top, spacing: 32) {
                            ForEach(bottom, id: \.self) { id in
                                Group {
                                    if id == "inbox" { inboxSection } else if id == "news" { newsSection } else { tasksSection }
                                }.frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                }.padding(.horizontal, 32).padding(.top, 26).padding(.bottom, 40)
            }
        }
    }

    private var subline: String {
        let n = attention.count
        let base = n == 0 ? "Nothing urgent right now." : n == 1 ? "One thing needs you today." : "\(n) things need you today."
        return base + " Nothing is sent or deleted without your approval."
    }

    private func runSearch() {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        model.section = .inbox; model.inboxFilter = .all
        NotificationCenter.default.post(name: .searchInbox, object: q)
    }

    // MARK: Sections

    private var briefingText: String? { model.briefingLive.flatMap { $0.isEmpty ? nil : $0 } ?? model.briefing?.text }

    /// "Drawn from 2 emails and 4 stories." Parts with nothing in them are left out.
    static func drawnFrom(_ b: Briefing) -> String {
        func n(_ c: Int, _ one: String) -> String? { c == 0 ? nil : "\(c) \(one)\(c == 1 ? "" : "s")" }
        let parts = [n(b.emailCount, "email"), n(b.storyCount, "story").map { $0.replacingOccurrences(of: "storys", with: "stories") }, n(b.eventCount, "event")].compactMap { $0 }
        guard !parts.isEmpty else { return "Written from your settings." }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "Drawn from \(list)." + (b.fullText != nil ? " Showing the short version." : "")
    }

    private var briefingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                SectionLabel("Daily briefing")
                if let b = model.briefing, !model.generatingBriefing { Text("Written \(b.generatedAt.relativeShort)").font(.ui(14)).foregroundStyle(Palette.text3).lineLimit(1).fixedSize() }
                if model.generatingBriefing { Text("Writing…").font(.ui(14)).foregroundStyle(Palette.text3) }
                Spacer()
                if model.briefing != nil {
                    Button { model.skim.toggle() } label: { Label("Highlights", systemImage: "highlighter") }.buttonStyle(QuietButtonStyle(compact: true, selected: model.skim)).fixedSize().help("Colour the key phrases for skim reading")
                    ListenButton(owner: "briefing", chunks: { [SkimMarkup.strip(model.briefing?.text ?? "")] })
                    Button(model.shorteningBriefing ? "Shortening…" : (model.briefing?.fullText != nil ? "Full length" : "Shorter")) { Task { await model.toggleShortBriefing() } }
                        .buttonStyle(QuietButtonStyle(compact: true, selected: model.briefing?.fullText != nil)).fixedSize().disabled(model.shorteningBriefing || model.generatingBriefing)
                        .help(model.briefing?.fullText != nil ? "Show the full briefing again" : "Summarise the briefing in a few sentences")
                }
                Button(model.briefing == nil ? "Write briefing" : "Rewrite") { Task { await model.generateBriefing() } }
                    .buttonStyle(QuietButtonStyle(compact: true)).disabled(model.generatingBriefing)
            }
            if let text = briefingText {
                SkimBody(text: text, size: 18, smooth: model.generatingBriefing)
                if !model.generatingBriefing, let b = model.briefing { Text(Self.drawnFrom(b)).font(.ui(13.5)).foregroundStyle(Palette.text3).transition(.opacity) }
            } else if model.generatingBriefing {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading your mail and the news…").font(.ui(15)).foregroundStyle(Palette.text2) }
            } else if !model.ai.isConfigured {
                Text("Add an AI provider key in Settings and your briefing will appear here each morning.").font(.ui(16)).foregroundStyle(Palette.text2)
                Button("Open AI settings") { model.settingsPane = .ai; model.section = .settings }.buttonStyle(PrimaryButtonStyle(compact: true))
            } else {
                Text("No briefing yet. It writes itself each morning, or press Write briefing.").font(.ui(16)).foregroundStyle(Palette.text2)
            }
            replyChips
            if !attention.isEmpty && !model.generatingBriefing {
                Hairline().padding(.top, 2)
                ForEach(attention) { att in
                    VStack(spacing: 0) {
                        attentionRow(att)
                        Hairline()
                    }.transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
        }
        .animation(Motion.snappy, value: attention.map(\.id))
    }

    /// One-tap replies to the briefing. AI-suggested when available, otherwise sensible defaults.
    @ViewBuilder private var replyChips: some View {
        if !model.generatingBriefing, model.briefing != nil, !attention.isEmpty {
            let suggested = (model.briefing?.replies ?? []).filter { !model.usedReplies.contains($0.id) }
            let allIDs = attention.flatMap { att -> [String] in switch att { case .row(let r): return [r.message.id]; case .bundle(let b): return b.rows.map { $0.message.id } } }
            // Without an AI key there are no suggestions, so offer one quiet default. With a key, wait for the AI's buttons instead of showing placeholders.
            let defaults = !model.ai.isConfigured
                ? [QuickReply(id: "d-remind", label: "Remind me tonight", kind: .remind, messageIds: Array(allIDs.prefix(3)))].filter { !model.usedReplies.contains($0.id) } : []
            // The AI writes the buttons for this situation. Repeats (same label, or a second "handled" button) are dropped.
            var seenLabels = Set<String>(), seenHandled = false
            let chips = (suggested + defaults).filter { q in
                if q.kind == .handled { if seenHandled { return false }; seenHandled = true }
                return seenLabels.insert(q.label.lowercased()).inserted
            }
            if !chips.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Text("REPLY").font(.ui(12, .semibold)).tracking(1.2).foregroundStyle(Palette.text3).padding(.top, 5)
                    FlowLayout(spacing: 8) {
                        ForEach(chips) { r in
                            Button { model.perform(r) } label: { Text(r.label).lineLimit(1).fixedSize() }.buttonStyle(QuietButtonStyle(compact: true))
                                .transition(.scale(scale: 0.9).combined(with: .opacity))
                        }
                    }
                    if model.briefing?.replies == nil, model.ai.isConfigured { ProgressView().controlSize(.mini).help("Thinking of replies…") }
                }.padding(.top, 2)
                .animation(Motion.spring, value: chips.map(\.id))
            }
        }
    }

    @ViewBuilder private func attentionRow(_ att: Att) -> some View {
        switch att {
        case .row(let r):
            HStack(spacing: 12) {
                Circle().fill(r.triage?.deadline != nil ? Palette.alertFG : Palette.accent).frame(width: 7, height: 7)
                Text(.init(attentionTitle(r))).font(.ui(15.5)).lineLimit(2)
                Spacer(minLength: 8)
                attentionButtons(handled: [r.message.threadId], ignore: [r.message], open: { model.selectedThread = r.message.threadId; model.section = .inbox }, task: r)
            }.padding(.vertical, 8)
        case .bundle(let b):
            HStack(spacing: 12) {
                Circle().fill(b.hasUrgent ? Palette.alertFG : Palette.accent).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text("**\(b.title)**: \(b.count) notices need a look").font(.ui(15.5))
                    Text(b.rows.prefix(3).map { $0.triage?.summary.isEmpty == false ? $0.triage!.summary : $0.message.subject }.joined(separator: " · ")).font(.ui(13.5)).foregroundStyle(Palette.text2).lineLimit(1)
                }
                Spacer(minLength: 8)
                attentionButtons(handled: b.rows.map { $0.message.threadId }, ignore: b.rows.map(\.message), open: { model.selectedBundleID = b.id; model.selectedThread = nil; model.section = .inbox }, task: nil)
            }.padding(.vertical, 8)
        }
    }

    @ViewBuilder private func attentionButtons(handled: [String], ignore: [EmailMessage], open: @escaping () -> Void, task: MailRow?) -> some View {
        if let r = task, r.triage?.needsReply == true { Button("Review") { open() }.buttonStyle(PrimaryButtonStyle(compact: true)) }
        else { Button("Open") { open() }.buttonStyle(QuietButtonStyle(compact: true)) }
        Menu {
            Button("That was me") { model.markHandled(handled) }
            if let r = task, let t = r.triage, !t.actionItems.isEmpty || t.deadline != nil {
                Button("Add as task") { model.perform(QuickReply(label: "", kind: .task, messageIds: [r.message.id])) }
            }
            Button("Remind me tonight") { model.perform(QuickReply(label: "", kind: .remind, messageIds: ignore.prefix(1).map(\.id))) }
            Button("Always treat mail like this as handled") { model.ignoreSimilar(Array(ignore.prefix(1))) }
        } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(QuietButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions")
    }

    private func attentionTitle(_ r: MailRow) -> String {
        let name = r.message.fromName
        if let t = r.triage {
            var s = "**\(name)**: \(t.summary.isEmpty ? r.message.subject : t.summary)"
            if let d = t.deadline { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; s += " Due \(f.string(from: d))." }
            return s
        }
        return "**\(name)**: \(r.message.subject)"
    }

    private var weatherSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Weather")
            if let w = model.weatherNow {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("\(Int(w.temperature.rounded()))°").font(.ui(40, .light))
                    Text(w.condition).font(.ui(15)).foregroundStyle(Palette.text2)
                    Spacer()
                    Text("H \(Int(w.high.rounded()))° · L \(Int(w.low.rounded()))°").font(.ui(13)).foregroundStyle(Palette.text3)
                }
                HStack {
                    ForEach(Array(w.hourly.enumerated().filter { $0.offset % 3 == 0 }.prefix(4)), id: \.offset) { _, p in
                        VStack(spacing: 2) {
                            Text(hour(p.date)).font(.ui(12.5)).foregroundStyle(Palette.text3)
                            Text("\(Int(p.temp.rounded()))°").font(.ui(14, .medium))
                        }.frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text("Weather for \(model.weather.city) will appear after the first refresh.").font(.ui(14.5)).foregroundStyle(Palette.text2)
            }
        }
    }
    private func hour(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "h a"; return f.string(from: d).lowercased() }

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Up next")
            switch model.calendar.calendarAccess {
            case .granted:
                let today = model.events.filter { Calendar.current.isDateInToday($0.start) || $0.start < Date().addingTimeInterval(18 * 3600) }.prefix(5)
                if today.isEmpty { Text("Nothing on the calendar.").font(.ui(15)).foregroundStyle(Palette.text2) }
                ForEach(Array(today)) { e in
                    HStack(spacing: 12) {
                        Text(e.isAllDay ? "All day" : timeString(e.start)).font(.ui(14.5)).foregroundStyle(Palette.text2).frame(width: 56, alignment: .leading)
                        Text(e.title).font(.ui(15.5)).lineLimit(1)
                    }
                }
            case .notDetermined:
                Text("See today's events here.").font(.ui(14.5)).foregroundStyle(Palette.text2)
                Button("Allow calendar access") { Task { _ = await model.calendar.requestCalendar(); model.events = model.calendar.upcoming() } }.buttonStyle(QuietButtonStyle(compact: true))
            case .denied:
                Text("Calendar access is off. Turn it on in System Settings → Privacy & Security → Calendars.").font(.ui(14)).foregroundStyle(Palette.text2)
            }
        }
    }
    private func timeString(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "h:mm"; return f.string(from: d) }

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { SectionLabel("Priority inbox"); Spacer(); Button("Open") { model.section = .inbox }.buttonStyle(.plain).font(.ui(14)).foregroundStyle(Palette.accentText) }
            if !model.mail.isConnected {
                Text("Connect your mail to see what needs you.").font(.ui(14.5)).foregroundStyle(Palette.text2)
                Button("Connect mail") { model.settingsPane = .accounts; model.section = .settings }.buttonStyle(QuietButtonStyle(compact: true))
            } else {
                let top = Array(MailBundler.items(from: model.rows.filter { $0.triage.map { $0.category != .newsletter && $0.category != .promo } ?? true }).prefix(4))
                if top.isEmpty { Text("No mail to show yet.").font(.ui(15)).foregroundStyle(Palette.text2) }
                ForEach(top) { item in
                    switch item {
                    case .thread(let r):
                        Button { model.selectedBundleID = nil; model.selectedThread = r.message.threadId; model.section = .inbox } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack { Text(r.message.fromName).font(.ui(15.5, .semibold)).lineLimit(1); Spacer(); if let t = r.triage { Chip(text: t.category.title, kind: chipKind(t)) } }
                                Text(r.triage?.summary.isEmpty == false ? r.triage!.summary : r.message.subject).font(.ui(14)).foregroundStyle(Palette.text2).lineLimit(1)
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Hairline()
                    case .bundle(let b):
                        Button { model.selectedBundleID = b.id; model.selectedThread = nil; model.section = .inbox } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack { Text(b.title).font(.ui(15.5, .semibold)).lineLimit(1); Text("\(b.count) emails").font(.ui(12.5)).foregroundStyle(Palette.text3); Spacer(); Chip(text: "Bundle", kind: .quiet) }
                                Text(b.rows.prefix(2).map(\.message.subject).joined(separator: " · ")).font(.ui(14)).foregroundStyle(Palette.text2).lineLimit(1)
                            }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Hairline()
                    }
                }
            }
        }
    }

    private var newsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { SectionLabel("Top news"); Spacer(); Button("Open") { model.section = .news }.buttonStyle(.plain).font(.ui(14)).foregroundStyle(Palette.accentText) }
            let top = model.stories.prefix(4)
            if top.isEmpty { Text(model.refreshingNews ? "Fetching the news…" : "No stories yet.").font(.ui(15)).foregroundStyle(Palette.text2) }
            ForEach(Array(top)) { s in
                Button { model.selectedStoryID = s.id; model.section = .news } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(s.categories.first?.title ?? "News"), \(s.sources.count) source\(s.sources.count == 1 ? "" : "s")").font(.ui(13)).foregroundStyle(Palette.text3)
                        Text(s.lead.title).font(.ui(15.5, .medium)).lineLimit(2).multilineTextAlignment(.leading)
                    }.padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Hairline()
            }
        }
    }

    private var tasksSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { SectionLabel("Tasks"); Spacer(); Button("Open") { model.section = .tasks }.buttonStyle(.plain).font(.ui(14)).foregroundStyle(Palette.accentText) }
            if model.openTasks.isEmpty { Text("Nothing to do.").font(.ui(15)).foregroundStyle(Palette.text2) }
            ForEach(model.openTasks.prefix(3)) { t in
                Button { model.toggle(t) } label: {
                    HStack(spacing: 10) { Image(systemName: "circle").font(.system(size: 14)).foregroundStyle(Palette.text3); Text(t.title).font(.ui(15.5)).lineLimit(1); Spacer() }.padding(.vertical, 3).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("Complete \(t.title)")
            }
            if !model.suggestions.isEmpty {
                Text("SUGGESTED FROM EMAIL").font(.ui(11.5, .semibold)).tracking(1.2).foregroundStyle(Palette.text3).padding(.top, 8)
                ForEach(model.suggestions.prefix(2)) { s in
                    HStack(spacing: 8) {
                        Text(s.title).font(.ui(14.5)).lineLimit(1)
                        Spacer()
                        Button { model.accept(s) } label: { Image(systemName: "checkmark") }.buttonStyle(PrimaryButtonStyle(compact: true)).accessibilityLabel("Accept suggestion")
                        Button { model.dismiss(s) } label: { Image(systemName: "xmark") }.buttonStyle(QuietButtonStyle(compact: true)).accessibilityLabel("Dismiss suggestion")
                    }.padding(.vertical, 3)
                }
            }
        }
    }

    private var customizePopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Dashboard").font(.ui(15, .semibold))
            ForEach([("briefing", "Daily briefing"), ("weather", "Weather"), ("calendar", "Up next"), ("inbox", "Priority inbox"), ("news", "Top news"), ("tasks", "Tasks")], id: \.0) { id, label in
                Toggle(label, isOn: Binding(get: { visible(id) }, set: { on in
                    if on { model.dashboardHidden.remove(id) } else { model.dashboardHidden.insert(id) }
                    model.prefs.set(Array(model.dashboardHidden), "dashboard.hidden")
                })).font(.ui(14.5))
            }
            Hairline()
            Toggle("Write briefing each morning", isOn: Binding(get: { model.prefs.bool("autoBriefing", default: true) }, set: { model.prefs.set($0, "autoBriefing") })).font(.ui(14.5))
        }.padding(16).frame(width: 260)
    }
}

func chipKind(_ t: Triage) -> Chip.Kind {
    switch t.category {
    case .needsReply, .actionItem: return .reply
    case .deadline: return .deadline
    case .important: return .important
    default: return .quiet
    }
}

extension Notification.Name { static let searchInbox = Notification.Name("everyday.searchInbox") }
