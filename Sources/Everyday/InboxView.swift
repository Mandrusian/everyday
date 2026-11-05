import SwiftUI
import AppKit
import EverydayCore

struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Local private var search = ""
    @Local private var active = ""   // debounced search text
    @FocusState private var keysFocused: Bool
    @Local private var showBulk = false
    private var bulkRows: [MailRow] { model.rows.filter { r in (r.triage.map { $0.category == .newsletter || $0.category == .promo } ?? false) && !model.mail.isVIP(r.message.fromAddress) } }

    private var filtered: [MailRow] {
        let base = active.isEmpty ? model.rows : model.mail.rows(search: active)
        switch model.inboxFilter {
        case .priority: return base.filter { $0.triage.map { $0.category != .newsletter && $0.category != .promo && $0.category != .spamSuspect } ?? true }
        case .needsReply: return base.filter { $0.triage?.needsReply == true }
        case .deadlines: return base.filter { $0.triage?.deadline != nil }
        case .newsletters: return base.filter { $0.triage.map { $0.category == .newsletter || $0.category == .promo } ?? false }
        case .all: return base
        }
    }

    /// Threads and bundles. Searching and the reply/deadline filters show plain threads.
    private var items: [InboxItem] {
        let rs = filtered
        let bundle = active.isEmpty && [.priority, .all, .newsletters].contains(model.inboxFilter)
        return bundle ? MailBundler.items(from: rs) : rs.map { .thread($0) }
    }
    /// j / k move, e archives, # trashes, u marks read, h marks handled. Each acts on the open conversation.
    private func handleKey(_ k: String) -> KeyPress.Result {
        let list = items
        let current = list.firstIndex { item in
            switch item { case .thread(let r): return model.selectedThread == r.message.threadId; case .bundle(let b): return model.selectedThread == nil && model.selectedBundleID == b.id }
        }
        func select(_ i: Int) {
            guard list.indices.contains(i) else { return }
            switch list[i] {
            case .thread(let r): model.selectedBundleID = nil; model.returnBundleID = nil; model.selectedThread = r.message.threadId
            case .bundle(let b): model.selectedBundleID = b.id; model.selectedThread = nil; model.returnBundleID = nil
            }
        }
        switch k {
        case "j": select((current ?? -1) + 1); return .handled
        case "k": select(max(0, (current ?? 1) - 1)); return .handled
        case "e": if let t = model.selectedThread { model.archiveThread(t); return .handled }
        case "#": if let t = model.selectedThread { model.trashThread(t); return .handled }
        case "u": if let t = model.selectedThread { model.markReadThread(t); return .handled }
        case "h": if let t = model.selectedThread { model.markHandled([t]); return .handled }
        default: break
        }
        return .ignored
    }

    private var selectedBundle: MailBundle? {
        guard let id = model.selectedBundleID else { return nil }
        for case .bundle(let b) in MailBundler.items(from: model.rows) where b.id == id { return b }
        return nil
    }

    var body: some View {
        if !model.mail.isConnected {
            VStack(spacing: 0) {
                PaneHeader(title: "Inbox")
                EmptyState(title: "Connect your mail", message: "everyday. reads your inbox on this Mac, sorts it with your own AI key, and never sends or deletes anything without your approval.",
                           action: ("Open account settings", { model.settingsPane = .accounts; model.section = .settings }))
            }
        } else {
            HStack(spacing: 0) {
                list.frame(width: 360)
                Hairline(vertical: true)
                Group {
                    if let b = selectedBundle, model.selectedThread == nil { BundleView(bundle: b).id(b.id) }
                    else if let id = model.selectedThread, !model.mail.thread(id).isEmpty { ThreadView(threadId: id).id(id) }
                    else { EmptyState(title: "Select a conversation", message: "Pick a message to read it, see a summary and draft a reply.") }
                }.frame(maxWidth: .infinity)
            }
            .animation(Motion.snappy, value: model.rows.map(\.id))
            .sheet(isPresented: $showBulk) { BulkArchiveSheet(rows: bulkRows) }
            .focusable().focused($keysFocused).focusEffectDisabled()
            .onKeyPress(characters: CharacterSet(charactersIn: "jkeuh#"), phases: .down) { handleKey($0.characters) }
            .onAppear { keysFocused = true; if model.selectedThread == nil && model.selectedBundleID == nil { model.selectedThread = filtered.first?.message.threadId } }
            .onReceive(NotificationCenter.default.publisher(for: .searchInbox)) { n in if let q = n.object as? String { search = q; active = q } }
        }
    }

    private var list: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Inbox", subtitle: model.triaging ? "Sorting…" : "Sorted by priority") {
                if model.syncingMail { ProgressView().controlSize(.small) }
                if model.inboxFilter == .newsletters, !bulkRows.isEmpty { Button("Review & archive…") { showBulk = true }.buttonStyle(QuietButtonStyle(compact: true)).help("See the list first. Nothing is archived until you confirm.") }
                Button { Task { await model.syncMail() } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(QuietButtonStyle(compact: true)).accessibilityLabel("Sync mail").help("Sync mail")
            }
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.text3)
                    TextField("Search mail", text: $search).accessibilityLabel("Search mail").textFieldStyle(.plain).font(.ui(14.5)).onSubmit { active = search }
                        .onChange(of: search) { _, v in if v.isEmpty { active = "" } }
                    if !search.isEmpty { Button { search = ""; active = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Palette.text3).accessibilityLabel("Clear search") }
                }.padding(.horizontal, 10).frame(height: 30).background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(InboxFilter.allCases) { f in
                            Button(f.rawValue) { model.inboxFilter = f }.buttonStyle(QuietButtonStyle(compact: true, selected: model.inboxFilter == f))
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.vertical, 12)
            Hairline()
            if model.syncingMail && model.rows.isEmpty {
                VStack(spacing: 0) { SkeletonRows(count: 7); Text(model.mailProgress.isEmpty ? "Fetching your mail. This takes a moment the first time." : model.mailProgress).font(.ui(14)).foregroundStyle(Palette.text3).padding(.top, 16); Spacer() }
            } else if items.isEmpty {
                EmptyState(title: "Nothing here", message: active.isEmpty ? "No messages match this view." : "No messages match “\(active)”.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                            Group {
                                switch item {
                                case .thread(let r): MailRowView(row: r, selected: model.selectedThread == r.message.threadId).onTapGesture { model.selectedBundleID = nil; model.returnBundleID = nil; model.selectedThread = r.message.threadId }
                                case .bundle(let b): BundleRowView(bundle: b, selected: model.selectedBundleID == b.id && model.selectedThread == nil).onTapGesture { model.selectedBundleID = b.id; model.selectedThread = nil; model.returnBundleID = nil }
                                }
                            }.entrance(idx).transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .move(edge: .leading))))
                        }
                    }
                }
            }
        }
    }
}

struct MailRowView: View {
    @Environment(AppModel.self) private var model
    let row: MailRow
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if row.message.isUnread { Circle().fill(Palette.accent).frame(width: 7, height: 7) }
                Text(row.message.fromName).font(.ui(16, row.message.isUnread ? .semibold : .regular)).lineLimit(1)
                if row.threadCount > 1 { Text("\(row.threadCount)").font(.ui(12.5)).foregroundStyle(Palette.text3) }
                if model.mail.accountEmails.count > 1 { Text(model.mail.owner(row.message).split(separator: "@").first.map(String.init) ?? "").font(.ui(11.5)).foregroundStyle(Palette.text3).padding(.horizontal, 6).padding(.vertical, 1).background(Capsule().fill(Palette.control)).lineLimit(1).help("Arrived in \(model.mail.owner(row.message))") }
                Spacer()
                Text(row.message.date.relativeShort).font(.ui(13)).foregroundStyle(Palette.text3)
            }
            Text(row.message.subject).font(.ui(15.5)).lineLimit(1)
            Text(row.triage?.summary.isEmpty == false ? row.triage!.summary : row.message.snippet).font(.ui(14.5)).foregroundStyle(Palette.text2).lineLimit(2)
            if let t = row.triage {
                HStack(spacing: 6) {
                    Chip(text: t.category.title, kind: chipKind(t))
                    if let d = t.deadline { Chip(text: "Due " + dayString(d), kind: .deadline) }
                }.padding(.top, 3)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.selected : .clear)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
    private func dayString(_ d: Date) -> String { let f = DateFormatter(); f.dateFormat = "EEE d MMM"; return f.string(from: d) }
}

struct ThreadView: View {
    @Environment(AppModel.self) private var model
    let threadId: String
    @Local private var summary: String?
    @Local private var summarizing = false
    @Local private var confirm: Confirm?
    @Local private var expanded: Set<String> = []
    @Local private var unsub: UnsubscribeTarget? = nil

    enum Confirm: Identifiable { case archive, trash; var id: Int { hashValue } }

    private var messages: [EmailMessage] { model.mail.thread(threadId) }

    var body: some View {
        let msgs = messages
        VStack(spacing: 0) {
            PaneHeader(title: msgs.last?.subject ?? "Conversation") {
                if let bid = model.returnBundleID { Button { model.selectedThread = nil; model.selectedBundleID = bid; model.returnBundleID = nil } label: { Label("Back to bundle", systemImage: "chevron.left") }.buttonStyle(QuietButtonStyle(compact: true)) }
                Button("That was me") { model.markHandled([threadId]) }.buttonStyle(QuietButtonStyle(compact: true)).help("Stop flagging this conversation. Nothing changes in your mail account.")
                Menu {
                    ForEach(AppModel.snoozeOptions(), id: \.title) { o in Button("\(o.title) · \(o.date.formatted(date: .abbreviated, time: .shortened))") { model.snooze(threadId, until: o.date, label: o.title) } }
                } label: { Text("Snooze") }.menuStyle(.button).buttonStyle(QuietButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().help("Hide it until later, with a reminder task. Nothing changes in your mail account.")
                if msgs.contains(where: \.isUnread) { Button("Mark read") { model.markReadThread(threadId) }.buttonStyle(QuietButtonStyle(compact: true)) }
                Button("Archive") { model.archiveThread(threadId) }.buttonStyle(QuietButtonStyle(compact: true))
                Button("Trash") { model.trashThread(threadId) }.buttonStyle(QuietButtonStyle(compact: true)).help("Moves it to Trash. You can restore it from there.")
                Menu {
                    Button("Always treat mail like this as handled") { if let m = msgs.last { model.ignoreSimilar([m]) } }
                    if let m = msgs.last { Button(model.mail.isVIP(m.fromAddress) ? "Remove VIP" : "Always important (VIP)") { model.toggleVIP(m.fromAddress) } }
                    if UnsubscribeTarget.parse(msgs.last?.listUnsubscribe) != nil { Divider(); Button("Unsubscribe…") { unsub = UnsubscribeTarget.parse(msgs.last?.listUnsubscribe) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(QuietButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    summaryCard(msgs)
                    ForEach(msgs) { m in messageBody(m, isLast: m.id == msgs.last?.id) }
                    ReplyComposer(threadId: threadId, lastMessage: msgs.last)
                }.padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .confirmationDialog(unsub.map { "Unsubscribe from \($0.host)?" } ?? "", isPresented: Binding(get: { unsub != nil }, set: { if !$0 { unsub = nil } }), titleVisibility: .visible) {
            if let u = unsub {
                if let w = u.web { Button("Open their unsubscribe page") { NSWorkspace.shared.open(w); model.say("Opened \(u.host)'s unsubscribe page in your browser.") } }
                if let m = u.mailto, let url = URL(string: "mailto:" + m) { Button("Write the unsubscribe email") { NSWorkspace.shared.open(url) } }
                Button("Cancel", role: .cancel) { }
            }
        } message: { Text("This opens the sender's own page or a pre-addressed email in your mail app. everyday. sends nothing itself.") }
        .task {
            summary = model.mail.cachedSummary(for: threadId)
            if summary == nil, model.ai.isConfigured, msgs.count > 1 { await summarize() }
            if let last = msgs.last, last.isUnread { expanded.insert(last.id) }
        }
    }

    private func act(_ done: String, _ work: @escaping () async throws -> Void) {
        Task { do { try await work(); model.reloadMail(); model.say(done) } catch { model.fail(error, "Mail") } }
    }

    private func summarize() async {
        summarizing = true; defer { summarizing = false }
        do { summary = try await model.mail.summary(for: threadId, regenerate: true) } catch { model.fail(error, "Summary") }
    }

    @ViewBuilder private func summaryCard(_ msgs: [EmailMessage]) -> some View {
        let t = msgs.last.flatMap { model.mail.triage(for: $0.id) }
        VStack(alignment: .leading, spacing: 8) {
            HStack { SectionLabel(msgs.count > 1 ? "Summary of \(msgs.count) messages" : "Summary"); Spacer()
                if summary != nil || t != nil { Button("Refresh") { Task { await summarize() } }.buttonStyle(.plain).font(.ui(13.5)).foregroundStyle(Palette.accentText).disabled(summarizing || !model.ai.isConfigured) } }
            if summarizing { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading the conversation…").font(.ui(15)).foregroundStyle(Palette.text2) } }
            else if let s = summary ?? t?.summary, !s.isEmpty { SkimBody(text: s, size: 16.5) }
            else if model.ai.isConfigured { Button("Summarize this conversation") { Task { await summarize() } }.buttonStyle(QuietButtonStyle(compact: true)) }
            else { Text("Add an AI provider key in Settings to get summaries.").font(.ui(15)).foregroundStyle(Palette.text2) }
            if let t, !t.actionItems.isEmpty {
                Text(t.actionItems.map { "• " + $0 }.joined(separator: "\n")).font(.ui(14.5)).foregroundStyle(Palette.text2)
                Button("Add to tasks") {
                    for a in t.actionItems { model.addTask(TaskItem(title: a, due: t.deadline, priority: t.priority >= 75 ? .high : .medium, source: .email, sourceDescription: msgs.last?.subject ?? "", threadId: threadId)) }
                    model.say("Added \(t.actionItems.count) task\(t.actionItems.count == 1 ? "" : "s").")
                }.buttonStyle(QuietButtonStyle(compact: true))
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
    }

    private func messageBody(_ m: EmailMessage, isLast: Bool) -> some View {
        let open = isLast || expanded.contains(m.id)
        return VStack(alignment: .leading, spacing: 6) {
            Button { if expanded.contains(m.id) { expanded.remove(m.id) } else { expanded.insert(m.id) } } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m.fromName).font(.ui(16, .semibold))
                        Text("\(m.fromAddress) · \(m.date.formatted(date: .abbreviated, time: .shortened))").font(.ui(13.5)).foregroundStyle(Palette.text3)
                    }
                    Spacer()
                    if m.hasAttachments { Image(systemName: "paperclip").foregroundStyle(Palette.text3).accessibilityLabel("Has attachments") }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Text(open ? m.body : String(m.snippet.prefix(160))).font(.ui(17)).lineSpacing(5).foregroundStyle(open ? Palette.text : Palette.text2).textSelection(.enabled)
                .lineLimit(open ? nil : 2)
            if open && !m.attachmentNames.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(m.attachmentNames, id: \.self) { n in
                        Menu {
                            Button("Preview with Quick Look") { Task { await model.previewAttachment(m, name: n) } }
                            Button("Save to Downloads") { Task { await model.saveAttachment(m, name: n) } }
                        } label: { Label(n, systemImage: "paperclip").lineLimit(1) }
                        .menuStyle(.button).buttonStyle(QuietButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().help("Downloads the file only when you choose an action")
                    }
                }.padding(.top, 4)
            }
            Hairline().padding(.top, 8)
        }
    }
}

struct ReplyComposer: View {
    @Environment(AppModel.self) private var model
    let threadId: String
    let lastMessage: EmailMessage?
    @Local private var tone = "Friendly"
    @Local private var text = ""
    @Local private var guidance = ""
    @Local private var generating = false
    @Local private var confirmSend = false
    @Local private var sending = false
    static let tones = ["Friendly", "Brief", "Formal"]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SectionLabel("Reply, draft only")
                Spacer()
                ForEach(Self.tones, id: \.self) { t in Button(t) { tone = t }.buttonStyle(QuietButtonStyle(compact: true, selected: tone == t)) }
                Button(text.isEmpty ? "Suggest reply" : "Redraft") { Task { await generate() } }.buttonStyle(PrimaryButtonStyle(compact: true)).disabled(generating || !model.ai.isConfigured)
            }
            TextField("What should the reply say? (optional)", text: $guidance).accessibilityLabel("What the reply should say").textFieldStyle(.plain).font(.ui(14.5)).padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised))
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text).accessibilityLabel("Reply draft").font(.ui(16.5)).scrollContentBackground(.hidden).padding(8).frame(minHeight: 130)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
                if text.isEmpty && !generating { Text("Write a reply, or press Suggest reply for a draft you can edit.").font(.ui(15)).foregroundStyle(Palette.text3).padding(14).allowsHitTesting(false) }
                if generating { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Drafting…").font(.ui(15)).foregroundStyle(Palette.text2) }.padding(14) }
            }
            HStack {
                Text("Nothing is sent until you press Send, and you then have 10 seconds to undo.").font(.ui(13.5)).foregroundStyle(Palette.text3)
                Spacer()
                Button("Save draft to Gmail") { Task { await saveDraft() } }.buttonStyle(QuietButtonStyle()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Review and send") { confirmSend = true }.buttonStyle(PrimaryButtonStyle()).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
            }
        }
        .onChange(of: model.restoredDrafts[threadId]) { _, v in if let v { text = v; model.restoredDrafts[threadId] = nil } }
        .sheet(isPresented: $confirmSend) { SendReview(threadId: threadId, to: lastMessage, text: text) { sent in if sent { text = "" } } }
    }

    private func generate() async {
        generating = true; defer { generating = false }
        do { text = try await model.mail.draft(for: threadId, tone: tone, myName: model.userName, guidance: guidance).text } catch { model.fail(error, "Draft") }
    }
    private func saveDraft() async {
        do { try await model.mail.saveDraft(threadId: threadId, body: text, .fromUserAction()); model.say("Draft saved in Gmail.") } catch { model.fail(error, "Draft") }
    }
}

struct SendReview: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let threadId: String
    let to: EmailMessage?
    let text: String
    let done: (Bool) -> Void
    @Local private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send this reply?").font(.ui(22, .medium))
            VStack(alignment: .leading, spacing: 4) {
                Text("To: \(to?.fromName ?? "") <\(to?.fromAddress ?? "")>").font(.ui(15))
                Text("Subject: Re: \(to?.subject.replacingOccurrences(of: "Re: ", with: "") ?? "")").font(.ui(15)).foregroundStyle(Palette.text2)
            }
            ScrollView { Text(text).font(.ui(16)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
                .frame(height: 200).padding(12).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
            Text("This will be sent from \(to.map { model.mail.owner($0) } ?? model.mail.accountEmail ?? "your account") immediately and cannot be unsent.").font(.ui(14)).foregroundStyle(Palette.text2)
            HStack { Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(sending ? "Sending…" : "Send") { send() }.buttonStyle(PrimaryButtonStyle()).disabled(sending)
            }
        }.padding(24).frame(width: 520).background(Palette.window)
    }

    private func send() {
        sending = true
        model.queueSend(threadId: threadId, body: text)    // held for 10 seconds so it can be undone
        done(true); dismiss()
    }
}
