import SwiftUI
import EverydayCore

struct TasksView: View {
    @Environment(AppModel.self) private var model
    enum Tab: String, CaseIterable { case upcoming = "Upcoming", today = "Today", completed = "Completed" }
    @Local private var tab: Tab = .upcoming
    @Local private var newTitle = ""
    @Local private var editing: TaskItem?
    @Local private var creating = false
    @Local private var hovered: String?
    @Local private var confirm: BulkDelete?
    enum BulkDelete: Identifiable { case completed, all; var id: Int { hashValue } }
    @FocusState private var addFocus: Bool

    private var shown: [TaskItem] {
        let cal = Calendar.current
        switch tab {
        case .upcoming: return model.openTasks
        case .today: return model.openTasks.filter { $0.due.map { cal.isDateInToday($0) || $0 < Date() } ?? false }
        case .completed: return model.doneTasks
        }
    }
    private var dueSoon: [TaskItem] { shown.filter { $0.due.map { $0 < Date().addingTimeInterval(7 * 86400) } ?? false } }
    private var later: [TaskItem] { shown.filter { t in !dueSoon.contains(where: { $0.id == t.id }) } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PaneHeader(title: "Tasks") {
                    ForEach(Tab.allCases, id: \.self) { t in Button(t.rawValue) { tab = t }.buttonStyle(QuietButtonStyle(compact: true, selected: tab == t)) }
                    Button("New task") { creating = true }.buttonStyle(PrimaryButtonStyle(compact: true))
                    Menu {
                        Button("Delete completed (\(model.doneTasks.count))") { confirm = .completed }.disabled(model.doneTasks.isEmpty)
                        Button("Delete all tasks…", role: .destructive) { confirm = .all }.disabled(model.openTasks.isEmpty && model.doneTasks.isEmpty)
                    } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(QuietButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().accessibilityLabel("More task actions")
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        progress.padding(.bottom, 10)
                        HStack(spacing: 8) {
                            TextField("Add a task, like “pay rent friday 5pm high”, and press Return", text: $newTitle).accessibilityLabel("Add a task").textFieldStyle(.plain).font(.ui(16.5)).focused($addFocus)
                                .padding(.horizontal, 12).frame(height: 36).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
                                .onSubmit { quickAdd() }
                        }.padding(.bottom, quickHint == nil ? 14 : 4)
                        if let h = quickHint { Text(h).font(.ui(13.5)).foregroundStyle(Palette.accentText).padding(.bottom, 14).transition(.opacity) }
                        if shown.isEmpty {
                            Text(tab == .completed ? "Nothing completed yet." : "No tasks here. Suggestions from your email appear on the right.").font(.ui(16)).foregroundStyle(Palette.text2).padding(.vertical, 20)
                        }
                        if tab == .completed { ForEach(shown) { row($0) } }
                        else {
                            if !dueSoon.isEmpty { SectionLabel("Due soon").padding(.bottom, 4); ForEach(dueSoon) { row($0) } }
                            if !later.isEmpty { SectionLabel("Later").padding(.top, 18).padding(.bottom, 4); ForEach(later) { row($0) } }
                        }
                    }.padding(.horizontal, 32).padding(.vertical, 20)
                }
            }
            Hairline(vertical: true)
            suggestionsPane.frame(width: 340)
        }
        .confirmationDialog(confirm == .all ? "Delete every task?" : "Delete all completed tasks?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
            if confirm == .all { Button("Delete all \(model.openTasks.count + model.doneTasks.count) tasks", role: .destructive) { withAnimation(Motion.snappy) { model.deleteAllTasks() } } }
            else { Button("Delete \(model.doneTasks.count) completed", role: .destructive) { withAnimation(Motion.snappy) { model.deleteCompletedTasks() } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone. Reminders created for them in Apple Reminders are removed too.") }
        .sheet(item: $editing) { t in TaskEditor(task: t, isNew: false) { model.update($0) } onDelete: { model.delete(t) } }
        .sheet(isPresented: $creating) { TaskEditor(task: TaskItem(title: ""), isNew: true) { model.addTask($0) } onDelete: {} }
        .onReceive(NotificationCenter.default.publisher(for: .newTask)) { _ in creating = true }
    }

    /// What the quick-add line will create, shown as you type.
    private var quickHint: String? {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard t.count > 2 else { return nil }
        let q = QuickAdd.parse(t)
        guard q.due != nil || q.priority != .medium || q.repeats != nil else { return nil }
        var parts = ["“\(q.title)”"]
        if let d = q.due { parts.append("due " + d.formatted(date: .abbreviated, time: Calendar.current.dateComponents([.hour, .minute], from: d) == DateComponents(hour: 0, minute: 0) ? .omitted : .shortened)) }
        if q.priority != .medium { parts.append(q.priority.title.lowercased() + " priority") }
        if let r = q.repeats { parts.append(r.title.lowercased()) }
        return parts.joined(separator: " · ")
    }

    private func quickAdd() {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        let q = QuickAdd.parse(t)
        var item = TaskItem(title: q.title, due: q.due ?? (q.repeats.map { $0.next(after: nil, now: Date().addingTimeInterval(-86400)) }), priority: q.priority); item.repeats = q.repeats
        withAnimation(Motion.snappy) { model.addTask(item) }
        newTitle = ""
    }

    private var progress: some View {
        let p = model.tasks.weekProgress()
        return HStack(spacing: 14) {
            Text("This week").font(.ui(15)).foregroundStyle(Palette.text2)
            GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Palette.control); Capsule().fill(Palette.accent).frame(width: p.total == 0 ? 0 : g.size.width * CGFloat(p.done) / CGFloat(p.total)) } }.frame(height: 4)
            Text("\(p.done) of \(p.total) done").font(.ui(15))
        }.padding(.vertical, 10).overlay(alignment: .top) { Hairline() }.overlay(alignment: .bottom) { Hairline() }
    }

    private func row(_ t: TaskItem) -> some View {
        HStack(spacing: 14) {
            Button { model.toggle(t) } label: { TaskCheck(done: t.isDone) }
                .buttonStyle(.plain).accessibilityLabel(t.isDone ? "Mark \(t.title) not done" : "Complete \(t.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(t.title + (t.repeats == nil ? "" : "  ↻")).font(.ui(17.5)).strikethrough(t.isDone).foregroundStyle(t.isDone ? Palette.text3 : Palette.text)
                if !t.sourceDescription.isEmpty || t.source != .manual { Text(t.source == .manual ? t.sourceDescription : "From email: \(t.sourceDescription)").font(.ui(14)).foregroundStyle(Palette.text3).lineLimit(1) }
            }
            Spacer()
            if !t.isDone { Chip(text: t.priority.title, kind: t.priority == .high ? .deadline : t.priority == .medium ? .reply : .quiet) }
            if let d = t.due { Text(dueString(d)).font(.ui(15)).foregroundStyle(d < Date() && !t.isDone ? Palette.alertFG : Palette.text2).frame(minWidth: 84, alignment: .trailing) }
            Button { withAnimation(Motion.snappy) { model.delete(t) } } label: { Image(systemName: "trash").font(.system(size: 13)) }
                .buttonStyle(.plain).foregroundStyle(Palette.text3).opacity(hovered == t.id ? 1 : 0.0).help("Delete task").accessibilityLabel("Delete \(t.title)")
        }
        .onHover { hovered = $0 ? t.id : (hovered == t.id ? nil : hovered) }
        .padding(.vertical, 12).overlay(alignment: .bottom) { Hairline() }.contentShape(Rectangle())
        .opacity(t.isDone ? 0.7 : 1).transition(.opacity.combined(with: .move(edge: .leading)))
        .onTapGesture(count: 2) { editing = t }
        .accessibilityAction(named: "Edit task") { editing = t }
        .accessibilityAction(named: t.isDone ? "Mark not done" : "Complete") { model.toggle(t) }
        .contextMenu { Button("Edit…") { editing = t }; Button(t.isDone ? "Mark not done" : "Complete") { model.toggle(t) }; Divider(); Button("Delete", role: .destructive) { model.delete(t) } }
    }

    private func dueString(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return "Today" }
        if cal.isDateInTomorrow(d) { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: d)
    }

    private var suggestionsPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: "Suggested for you", subtitle: model.suggestions.isEmpty ? nil : "\(model.suggestions.count) new")
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Found in your email. Nothing is added until you accept it.").font(.ui(14.5)).foregroundStyle(Palette.text2)
                    if model.suggestions.isEmpty {
                        Text(model.mail.isConnected ? (model.ai.isConfigured ? "No suggestions right now." : "Nothing with a deadline in your unread mail right now. Add an AI key in Settings for smarter suggestions.") : "Connect your mail to get suggestions.").font(.ui(15)).foregroundStyle(Palette.text3)
                    }
                    ForEach(model.suggestions) { s in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(s.title).font(.ui(17))
                            Text("\(s.sourceDescription). Priority: \(s.priority.title)\(s.due.map { ", due " + dueString($0) } ?? "").").font(.ui(14)).foregroundStyle(Palette.text2)
                            HStack(spacing: 8) {
                                Button("Add task") { model.accept(s) }.buttonStyle(PrimaryButtonStyle(compact: true))
                                Button("Dismiss") { model.dismiss(s) }.buttonStyle(QuietButtonStyle(compact: true))
                                if let tid = s.threadId { Button("Open email") { model.selectedThread = tid; model.section = .inbox }.buttonStyle(.plain).font(.ui(13.5)).foregroundStyle(Palette.accentText) }
                            }.padding(.top, 2)
                            Hairline().padding(.top, 8)
                        }
                    }
                }.padding(24)
            }
            Hairline()
            RemindersToggle().padding(.horizontal, 24).padding(.vertical, 14)
        }.background(Palette.sidebar)
    }
}

struct RemindersToggle: View {
    @Environment(AppModel.self) private var model
    @Local private var on = Prefs.shared.bool(Prefs.Key.remindersSync)
    var body: some View {
        Toggle("Sync with Apple Reminders", isOn: Binding(get: { on }, set: { v in
            if v {
                Task {
                    let ok = model.calendar.reminderAccess == .granted ? true : await model.calendar.requestReminders()
                    on = ok; model.prefs.set(ok, Prefs.Key.remindersSync)
                    if !ok { model.say("Reminders access was not granted. Turn it on in System Settings → Privacy & Security → Reminders.", error: true) }
                }
            } else { on = false; model.prefs.set(false, Prefs.Key.remindersSync) }
        })).font(.ui(15)).toggleStyle(.switch).accessibilityLabel("Sync with Apple Reminders")
    }
}

struct TaskEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Local var task: TaskItem
    let isNew: Bool
    let onSave: (TaskItem) -> Void
    let onDelete: () -> Void
    @Local private var hasDue = false
    @Local private var due = Date().addingTimeInterval(86400)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New task" : "Edit task").font(.ui(22, .medium))
            TextField("Title", text: $task.title).accessibilityLabel("Task title").textFieldStyle(.plain).font(.ui(16)).padding(.horizontal, 10).frame(height: 34).background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised))
            TextField("Notes", text: $task.notes, axis: .vertical).accessibilityLabel("Task notes").lineLimit(3...5).textFieldStyle(.plain).font(.ui(15)).padding(10).background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised))
            Toggle("Due date", isOn: $hasDue).font(.ui(15))
            if hasDue { DatePicker("Due date", selection: $due, displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
            Picker("Repeat", selection: $task.repeats) { Text("Never").tag(TaskRepeat?.none); ForEach(TaskRepeat.allCases) { Text($0.title).tag(TaskRepeat?.some($0)) } }.font(.ui(15))
            Picker("Priority", selection: $task.priority) { ForEach(TaskPriority.allCases) { Text($0.title).tag($0) } }.pickerStyle(.segmented).font(.ui(15))
            HStack {
                if !isNew { Button("Delete", role: .destructive) { onDelete(); dismiss() }.buttonStyle(QuietButtonStyle()) }
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(isNew ? "Add" : "Save") { var t = task; t.due = hasDue ? due : nil; t.title = t.title.trimmingCharacters(in: .whitespaces); onSave(t); dismiss() }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(task.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(24).frame(width: 440).background(Palette.window)
        .onAppear { if let d = task.due { hasDue = true; due = d } }
    }
}

struct AssistantPanel: View {
    @Environment(AppModel.self) private var model
    @Local private var input = ""
    @Local private var showContext = false

    private var openContext: String {
        var parts: [String] = []
        if model.section == .inbox, let id = model.selectedThread {
            let msgs = model.mail.thread(id)
            if !msgs.isEmpty { parts.append("Email thread \"\(msgs.last!.subject)\":\n" + msgs.suffix(4).map { "From \($0.fromName): \(ContextRedactor.clean($0.body, limit: 1200))" }.joined(separator: "\n---\n")) }
        }
        if model.section == .news, let s = model.stories.first(where: { $0.id == model.selectedStoryID }) {
            parts.append("Article being read: \(s.lead.title) (\(s.lead.source)). \(s.lead.summary)")
        }
        return parts.joined(separator: "\n\n")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Ask everyday.").font(.ui(18, .semibold))
                Spacer()
                Button("Clear") { model.clearChat() }.buttonStyle(QuietButtonStyle(compact: true)).disabled(model.chat.isEmpty)
                Button { model.showAssistant = false } label: { Image(systemName: "xmark") }.buttonStyle(QuietButtonStyle(compact: true)).accessibilityLabel("Close assistant")
            }.padding(.horizontal, 18).frame(height: 52).overlay(alignment: .bottom) { Hairline() }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.chat.isEmpty {
                            Text("I can see your triaged mail, tasks, calendar and news. Ask me what needs attention, to summarize something, or to find an email.").font(.ui(15.5)).foregroundStyle(Palette.text2)
                            ForEach(["What needs my attention today?", "Which emails are waiting on a reply?", "What are the most important stories this morning?"], id: \.self) { q in
                                Button(q) { model.ask(q, extraContext: openContext) }.buttonStyle(QuietButtonStyle(compact: true))
                            }
                        }
                        ForEach(model.chat) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.role == .user ? "You" : "everyday.").font(.ui(12.5, .semibold)).foregroundStyle(m.role == .user ? Palette.text3 : Palette.accentText)
                                if m.text.isEmpty { Text("…").font(.ui(16)).foregroundStyle(Palette.text3) } else { SkimBody(text: m.text, size: 17.5, smooth: model.chatStreaming && m.id == model.chat.last?.id) }
                                if let src = m.sources, !src.isEmpty {
                                    FlowLayout(spacing: 6) {
                                        ForEach(Array(src.enumerated()), id: \.element.id) { i, c in
                                            Button { model.open(c) } label: { Text("\(i + 1)  \(c.title)").lineLimit(1).frame(maxWidth: 230) }.buttonStyle(QuietButtonStyle(compact: true)).help("Open the \(c.kind == .mail ? "email" : "story")")
                                        }
                                    }.padding(.top, 4)
                                }
                            }.id(m.id)
                        }
                    }.padding(18)
                }
                .onChange(of: model.chat.last?.text) { _, _ in if let id = model.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            }
            Hairline()
            VStack(alignment: .leading, spacing: 8) {
                Button { showContext.toggle() } label: { Text(showContext ? "Hide what is sent" : "What is sent to \(model.ai.providerID.title)?").font(.ui(13)).foregroundStyle(Palette.text3) }.buttonStyle(.plain)
                if showContext {
                    ScrollView { Text(model.context.snapshot(emailLimit: 15, storyLimit: 12).text + (openContext.isEmpty ? "" : "\n\nCURRENTLY OPEN:\n" + openContext)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.text2).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(height: 140).padding(8).background(RoundedRectangle(cornerRadius: 6).fill(Palette.raised))
                }
                HStack(spacing: 8) {
                    TextField("Ask about your mail, news or tasks", text: $input, axis: .vertical).accessibilityLabel("Ask everyday.").textFieldStyle(.plain).font(.ui(15.5)).lineLimit(1...4)
                        .padding(.horizontal, 12).padding(.vertical, 8).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised)).onSubmit { send() }
                    Button("Send") { send() }.buttonStyle(PrimaryButtonStyle()).disabled(model.chatStreaming || input.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }.padding(14)
        }.background(Palette.sidebar)
    }

    private func send() { let q = input; input = ""; model.ask(q, extraContext: openContext) }
}
