import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EverydayCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Local private var query = ""

    private static let keywords: [SettingsPane: String] = [
        .general: "name city weather rules ignore vip senders onboarding setup",
        .briefing: "morning briefing sections hide topics instructions rewrite news count",
        .voice: "voice speech tts listen speed gemini audio cache",
        .accounts: "mail gmail imap password icloud fastmail yahoo sync account",
        .ai: "ai key gemini claude openai anthropic model provider activity log local ollama",
        .sources: "news sources rss atom feeds opml import export promos",
        .interests: "interests topics swipe retrain categories",
        .privacy: "privacy delete data keychain redact local",
        .notifications: "notifications reminders alerts briefing time",
        .appearance: "appearance theme dark light highlight skim colours font size motion",
        .widgets: "widgets desktop clock weather calendar quote brief notification centre",
        .advanced: "advanced prompt briefing instructions system custom edit reset",
    ]
    private var matches: [SettingsPane] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return SettingsPane.allCases }
        return SettingsPane.allCases.filter { $0.rawValue.lowercased().contains(q) || (Self.keywords[$0] ?? "").contains(q) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                PaneHeader(title: "Settings")
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Palette.text3)
                    TextField("Search settings", text: $query).accessibilityLabel("Search settings").textFieldStyle(.plain).font(.ui(14.5))
                        .onSubmit { if let f = matches.first { model.settingsPane = f } }
                        .onChange(of: query) { _, _ in if let f = matches.first, !matches.contains(model.settingsPane) { model.settingsPane = f } }
                    if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Palette.text3).accessibilityLabel("Clear search") }
                }.padding(.horizontal, 10).frame(height: 30).background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised)).padding(.horizontal, 10).padding(.top, 10)
                VStack(spacing: 1) {
                    ForEach(matches) { p in
                        Button { model.settingsPane = p } label: {
                            Text(p.rawValue).font(.ui(16, model.settingsPane == p ? .semibold : .regular)).foregroundStyle(model.settingsPane == p ? Palette.text : Palette.text2)
                                .padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 6).fill(model.settingsPane == p ? Palette.control : .clear)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if matches.isEmpty { Text("No settings match.").font(.ui(14)).foregroundStyle(Palette.text3).padding(.top, 8) }
                }.padding(10)
                Spacer()
            }.frame(width: 210)
            Hairline(vertical: true)
            VStack(spacing: 0) {
                PaneHeader(title: model.settingsPane.rawValue)
                ScrollView {
                    Group {
                        switch model.settingsPane {
                        case .general: GeneralPane()
                        case .briefing: BriefingPane()
                        case .voice: VoicePane()
                        case .accounts: AccountsPane()
                        case .ai: AIPane()
                        case .sources: SourcesPane()
                        case .interests: InterestsPane()
                        case .privacy: PrivacyPane()
                        case .notifications: NotificationsPane()
                        case .appearance: AppearancePane()
                        case .widgets: WidgetsPane()
                        case .advanced: AdvancedPane()
                        }
                    }.padding(.horizontal, 40).padding(.vertical, 28).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity)
        }
    }
}

struct Field: View {
    let title: String
    @Binding var text: String
    var secure = false
    var placeholder = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(14)).foregroundStyle(Palette.text3)
            Group { if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) } }.accessibilityLabel(title)
                .textFieldStyle(.plain).font(.ui(16)).padding(.horizontal, 12).frame(height: 36).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
        }
    }
}

struct Row<Content: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.ui(16.5))
                if let d = detail { Text(d).font(.ui(14)).foregroundStyle(Palette.text3) }
            }
            Spacer(minLength: 12)
            content()
        }.padding(.vertical, 11).overlay(alignment: .bottom) { Hairline() }
    }
}

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @Local private var name = Prefs.shared.string("userName", default: NSFullUserName().components(separatedBy: " ").first ?? "")
    @Local private var city = Prefs.shared.string(Prefs.Key.city, default: "Sydney")
    @Local private var days = Prefs.shared.double(Prefs.Key.syncDays, default: 30)
    @Local private var hour = Prefs.shared.double(Prefs.Key.briefingHour, default: 7)
    @Local private var cityStatus = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Field(title: "Your first name", text: $name).onChange(of: name) { _, v in model.prefs.set(v, "userName") }
            HStack(alignment: .bottom, spacing: 10) {
                Field(title: "City for weather", text: $city)
                Button("Check") { Task {
                    model.weather.city = city
                    do { let w = try await model.weather.fetch(); model.weatherNow = w; cityStatus = "\(w.city): \(Int(w.temperature.rounded()))°, \(w.condition.lowercased())" } catch { cityStatus = error.localizedDescription }
                } }.buttonStyle(QuietButtonStyle())
            }
            if !cityStatus.isEmpty { Text(cityStatus).font(.ui(14)).foregroundStyle(Palette.text2) }
            Row(title: "Mail history to keep", detail: "Days of inbox stored on this Mac.") {
                Stepper("\(Int(days)) days", value: $days, in: 7...90, step: 7).font(.ui(15)).onChange(of: days) { _, v in model.prefs.set(v, Prefs.Key.syncDays) }
            }
            Row(title: "Briefing time", detail: "The briefing writes itself after this hour.") {
                Stepper(String(format: "%d:00", Int(hour)), value: $hour, in: 4...12).font(.ui(15)).onChange(of: hour) { _, v in model.prefs.set(v, Prefs.Key.briefingHour) }
            }
            Row(title: "Updates", detail: "Version \(model.appVersion). Looks for a newer version once a day and shows you the download page. It sends nothing about you and installs nothing by itself.") {
                HStack(spacing: 10) {
                    Toggle("Check for updates automatically", isOn: Binding(get: { model.prefs.bool(Prefs.Key.autoUpdateCheck, default: true) }, set: { model.prefs.set($0, Prefs.Key.autoUpdateCheck) })).labelsHidden()
                    Button("Check now") { Task { await model.checkForUpdates(manual: true) } }.buttonStyle(QuietButtonStyle(compact: true))
                    if let u = model.availableUpdate { Button("Get \(u.version)") { NSWorkspace.shared.open(u.url) }.buttonStyle(PrimaryButtonStyle(compact: true)) }
                }
            }
            RulesSection()
            Row(title: "Redo onboarding", detail: "Walk through setup again. Your data is kept.") {
                Button("Start") { model.prefs.set(false, Prefs.Key.onboarded); model.showOnboarding = true }.buttonStyle(QuietButtonStyle())
            }
        }
    }
}

/// Mail you told everyday. to stop flagging. Local only; removing a rule brings the mail back into attention lists.
struct RulesSection: View {
    @Environment(AppModel.self) private var model
    @Local private var rules: [MailRule] = []
    @Local private var vips: [String] = []
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Mail you've told it to ignore").padding(.top, 8)
            if rules.isEmpty { Text("None yet. Choose “Always treat mail like this as handled” on an email or a briefing item.").font(.ui(14.5)).foregroundStyle(Palette.text3) }
            ForEach(rules) { r in
                HStack { Text(r.summary).font(.ui(15)); Spacer(); Button("Remove") { model.mail.removeRule(r); rules = model.mail.rules(); model.reloadMail(); model.reloadTasks() }.buttonStyle(QuietButtonStyle(compact: true)) }
                    .padding(.vertical, 6).overlay(alignment: .bottom) { Hairline() }
            }
            SectionLabel("VIP senders").padding(.top, 14)
            if vips.isEmpty { Text("None yet. Choose “Always important (VIP)” on a conversation. Their mail always rises to the top.").font(.ui(14.5)).foregroundStyle(Palette.text3) }
            ForEach(vips, id: \.self) { a in
                HStack { Text(a).font(.ui(15)); Spacer(); Button("Remove") { model.mail.setVIP(a, false); vips = model.mail.vips(); model.reloadMail() }.buttonStyle(QuietButtonStyle(compact: true)) }
                    .padding(.vertical, 6).overlay(alignment: .bottom) { Hairline() }
            }
        }.onAppear { rules = model.mail.rules(); vips = model.mail.vips() }
    }
}

/// What the morning briefing covers, what to hide, and standing instructions in the reader's own words.
struct BriefingPane: View {
    @Environment(AppModel.self) private var model
    @Local private var sections: Set<String> = Set(Prefs.shared.strings(Prefs.Key.briefingSections).isEmpty ? ContextBuilder.allSections : Prefs.shared.strings(Prefs.Key.briefingSections))
    @Local private var newsCount = Prefs.shared.double(Prefs.Key.briefingNewsCount, default: 3)
    @Local private var instructions = Prefs.shared.string(Prefs.Key.briefingInstructions)
    @Local private var muted: [String] = Prefs.shared.strings(Prefs.Key.mutedTopics)
    @Local private var newTopic = ""
    @Local private var autoRewrite = Prefs.shared.bool(Prefs.Key.briefingAutoRewrite, default: true)
    static let titles = [("mail", "Mail that needs me", "Replies owed and deadlines"), ("calendar", "Calendar", "Today's events"), ("weather", "Weather", "One line"), ("news", "News", "A few top stories"), ("tasks", "Tasks", "What is open and due")]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Tell everyday. what you want to see each morning. Changes apply the next time a briefing is written.").font(.ui(16)).foregroundStyle(Palette.text2)
            SectionLabel("Include")
            ForEach(Self.titles, id: \.0) { id, title, detail in
                Row(title: title, detail: detail) {
                    Toggle("Include \(id) in briefing", isOn: Binding(get: { sections.contains(id) }, set: { on in if on { sections.insert(id) } else { sections.remove(id) }; save() })).labelsHidden()
                }
            }
            Row(title: "Stories to mention", detail: "How many news stories the briefing may cover. Zero leaves news out.") {
                Stepper("\(Int(newsCount))", value: $newsCount, in: 0...8).font(.ui(15)).onChange(of: newsCount) { _, v in model.prefs.set(v, Prefs.Key.briefingNewsCount) }
            }
            SectionLabel("In your own words").padding(.top, 8)
            Text("Standing instructions the AI follows every time. For example: “Skip anything about Hong Kong and chip makers. I care about AI policy, aviation and Australian politics. Keep it under 100 words.”").font(.ui(14)).foregroundStyle(Palette.text3)
            TextEditor(text: $instructions).accessibilityLabel("Standing instructions for the briefing").font(.ui(15)).scrollContentBackground(.hidden).padding(8).frame(minHeight: 110)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
                .onChange(of: instructions) { _, v in model.prefs.set(v, Prefs.Key.briefingInstructions) }
            SectionLabel("Hide these topics everywhere").padding(.top, 8)
            Text("Stories mentioning any of these words disappear from the briefing, Top news and the reader's list.").font(.ui(14)).foregroundStyle(Palette.text3)
            HStack(spacing: 8) {
                TextField("Add a word or phrase, then press Return", text: $newTopic).accessibilityLabel("Hide a topic").textFieldStyle(.plain).font(.ui(15)).padding(.horizontal, 10).frame(height: 32).background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised)).onSubmit { add() }
                Button("Add") { add() }.buttonStyle(QuietButtonStyle()).disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100, maximum: 240), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(muted, id: \.self) { t in
                    HStack(spacing: 6) { Text(t).font(.ui(14)); Button { muted.removeAll { $0 == t }; save(); model.reloadNews() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).accessibilityLabel("Remove \(t)") }
                        .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Palette.control))
                }
            }
            Row(title: "Rewrite when I mark things handled", detail: "After “That was me”, the briefing is written again without it.") {
                Toggle("Rewrite when I mark things handled", isOn: $autoRewrite).labelsHidden().onChange(of: autoRewrite) { _, v in model.prefs.set(v, Prefs.Key.briefingAutoRewrite) }
            }
            HStack { Button(model.generatingBriefing ? "Writing…" : "Write the briefing now") { Task { await model.generateBriefing() } }.buttonStyle(PrimaryButtonStyle()).disabled(model.generatingBriefing); Spacer() }.padding(.top, 6)
        }
    }

    private func add() {
        let t = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !muted.contains(where: { $0.lowercased() == t.lowercased() }) else { newTopic = ""; return }
        muted.append(t); newTopic = ""; save(); model.reloadNews()
    }
    private func save() {
        model.prefs.set(ContextBuilder.allSections.filter { sections.contains($0) }, Prefs.Key.briefingSections)
        model.prefs.set(muted, Prefs.Key.mutedTopics)
    }
}

/// Voice for Listen: natural (Gemini) or the voices installed on this Mac.
struct VoicePane: View {
    @Environment(AppModel.self) private var model
    @Local private var engine = SpeechService.shared.engine
    @Local private var voice = SpeechService.shared.naturalVoice
    @Local private var speed = SpeechService.shared.speed
    @Local private var showFemale = false
    @Local private var systemVoice = SpeechService.shared.voiceID
    @Local private var cacheBytes = 0
    private var speech: SpeechService { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose how everyday. reads to you. Natural voices (Gemini) sound like a person but send the text to Google with your key. “On this Mac” uses Apple’s voices: Premium and Enhanced ones are neural and sound natural, run offline and send nothing anywhere. Standard ones are robotic.").font(.ui(16)).foregroundStyle(Palette.text2)
            HStack(spacing: 6) {
                Button("Natural (Gemini)") { engine = .natural; speech.engine = .natural }.buttonStyle(QuietButtonStyle(selected: engine == .natural))
                Button("On this Mac (offline)") { engine = .system; speech.engine = .system }.buttonStyle(QuietButtonStyle(selected: engine == .system))
            }
            if engine == .natural {
                if !speech.naturalAvailable {
                    Text("Natural voices need a Gemini API key. Add one in Settings → AI provider and choose Gemini. Until then everyday. uses the system voice.").font(.ui(15)).foregroundStyle(Palette.warnFG)
                }
                SectionLabel("Voice")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 240), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 8) {
                    ForEach(GeminiSpeech.voices.filter { $0.male || showFemale }) { v in
                        Button { voice = v.id; speech.naturalVoice = v.id; speech.preview() } label: { Text(v.title).lineLimit(1) }
                            .buttonStyle(QuietButtonStyle(compact: true, selected: voice == v.id))
                    }
                }
                Button(showFemale ? "Hide other voices" : "Show other voices") { withAnimation(Motion.snappy) { showFemale.toggle() } }.buttonStyle(.plain).font(.ui(14)).foregroundStyle(Palette.accentText)
                Text("Pressing a voice plays a short sample.").font(.ui(13.5)).foregroundStyle(Palette.text3)
            } else {
                SectionLabel("Installed voices")
                let voices = speech.voices()
                Picker("Voice", selection: $systemVoice) {
                    Text("Best available").tag("")
                    ForEach(voices, id: \.identifier) { v in Text("\(v.name) · \(SpeechService.qualityName(v)) · \(v.language)").tag(v.identifier) }
                }.labelsHidden().frame(maxWidth: 420).onChange(of: systemVoice) { _, v in speech.voiceID = v }
                if !voices.contains(where: { $0.quality != .default }) {
                    Text("Only Standard voices are installed, and those sound robotic. For a natural offline voice, open System Settings → Accessibility → Spoken Content → System Voice → Manage Voices and download a Premium or Enhanced one (try Evan, Zoe or Ava), then pick it here.").font(.ui(14)).foregroundStyle(Palette.warnFG)
                }
                Button("Open Spoken Content settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension")!) }.buttonStyle(QuietButtonStyle(compact: true))
            }
            Row(title: "Speed", detail: String(format: "%.2fx", speed)) {
                Slider(value: $speed, in: 0.75...1.5, step: 0.05).accessibilityLabel("Speech speed").frame(width: 220).onChange(of: speed) { _, v in speech.speed = v }
            }
            HStack(spacing: 10) {
                Button(speech.isSpeaking && speech.owner == "preview" ? "Stop" : "Play a sample") { speech.isSpeaking && speech.owner == "preview" ? speech.stop() : speech.preview() }.buttonStyle(PrimaryButtonStyle())
                if speech.loading { ProgressView().controlSize(.small) }
            }
            if let e = speech.lastError { Text("The natural voice could not be used, so the system voice was used instead: \(e)").font(.ui(14)).foregroundStyle(Palette.alertFG) }
            if engine == .natural {
                Row(title: "Saved audio", detail: "Audio is kept on this Mac so replays are instant and free. \(ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file)) used.") {
                    Button("Clear") { model.ai.speechClient()?.clearCache(); cacheBytes = 0 }.buttonStyle(QuietButtonStyle(compact: true))
                }
                Text("Natural voices send the text being read to Google through your Gemini key. Each request appears in Settings → AI provider → activity log.").font(.ui(13.5)).foregroundStyle(Palette.text3)
            }
        }.onAppear { cacheBytes = model.ai.speechClient()?.cacheSize() ?? 0 }
    }
}

/// Desktop and Notification Centre widgets, and the topic for the daily quote.
struct WidgetsPane: View {
    @Environment(AppModel.self) private var model
    @Local private var topic = Prefs.shared.string(Prefs.Key.quoteTopic, default: "Stoicism")
    @Local private var style = Prefs.shared.string(Prefs.Key.widgetStyle, default: "glass")
    @Local private var busy = false
    @Local private var newTitle = ""
    @Local private var newDate = Date().addingTimeInterval(86400 * 7)
    @Local private var customs: [WidgetSnapshot.Custom] = []
    @Local private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("To add a widget, right-click the desktop, choose Edit Widgets and search for “everyday.”. They update whenever the app refreshes and read only a small summary saved on this Mac.").font(.ui(15)).foregroundStyle(Palette.text2)

            SectionLabel("Look").padding(.top, 6)
            Picker("Widget look", selection: $style) { Text("Flat paper").tag("flat"); Text("Liquid Glass").tag("glass") }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                .onChange(of: style) { _, v in model.prefs.set(v, Prefs.Key.widgetStyle); model.updateWidgets() }
            Text("Flat paper uses the app's colours. Liquid Glass lets the desktop show through. Custom widgets can choose their own.").font(.ui(13.5)).foregroundStyle(Palette.text3)

            SectionLabel("Countdowns").padding(.top, 6)
            ForEach(Array(model.widgetCountdowns.enumerated()), id: \.offset) { i, c in
                HStack {
                    Text(c.title).font(.ui(15)).foregroundStyle(Palette.text)
                    Text(c.date.formatted(date: .abbreviated, time: .omitted)).font(.ui(14)).foregroundStyle(Palette.text3)
                    Spacer()
                    Button("Remove") { var l = model.widgetCountdowns; l.remove(at: i); model.widgetCountdowns = l }.buttonStyle(QuietButtonStyle())
                }
            }
            HStack(alignment: .bottom, spacing: 10) {
                Field(title: "Counting down to", text: $newTitle, placeholder: "Holidays, a launch, a birthday…")
                DatePicker("Date", selection: $newDate, displayedComponents: .date).labelsHidden().frame(width: 130)
                Button("Add") {
                    let t = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !t.isEmpty else { return }
                    model.widgetCountdowns = model.widgetCountdowns + [.init(title: t, date: newDate)]
                    newTitle = ""
                }.buttonStyle(QuietButtonStyle()).disabled(newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Text("The Countdown widget shows the nearest one.").font(.ui(13.5)).foregroundStyle(Palette.text3)

            SectionLabel("Build your own").padding(.top, 6)
            Text("Pick up to six blocks for each of the Custom 1, 2 and 3 widgets. Small widgets show the first two, medium the first three.").font(.ui(14.5)).foregroundStyle(Palette.text2)
            ForEach(customs.indices, id: \.self) { i in customEditor(i) }
            if customs.count < 3 {
                Button("New custom widget") { customs.append(.init(name: "Custom \(customs.count + 1)", style: style, blocks: ["clock", "weather", "next"])); saveCustoms() }.buttonStyle(QuietButtonStyle())
            }

            SectionLabel("Quote of the day").padding(.top, 6)
            HStack(alignment: .bottom, spacing: 10) {
                Field(title: "Topic", text: $topic, placeholder: "Stoicism, flying, design, Australian history…")
                Button(busy ? "Finding…" : "New quote") { save(); Task { busy = true; await model.refreshQuote(force: true); busy = false } }.buttonStyle(QuietButtonStyle()).disabled(busy || !model.ai.isConfigured)
            }
            .onSubmit { save() }
            if !model.ai.isConfigured { Text("The quote needs an AI key (Settings → AI provider). The other widgets work without one.").font(.ui(14)).foregroundStyle(Palette.warnFG) }
            HStack { Button("Refresh widgets now") { model.updateWidgets() }.buttonStyle(QuietButtonStyle()); Spacer() }.padding(.top, 4)
        }
        .onAppear { if !loaded { customs = model.widgetCustoms; loaded = true } }
    }

    @ViewBuilder private func customEditor(_ i: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Custom \(i + 1)").font(.ui(15.5, .semibold)).foregroundStyle(Palette.text)
                Spacer()
                Picker("Look for Custom \(i + 1)", selection: Binding(get: { customs[i].style }, set: { customs[i].style = $0; saveCustoms() })) { Text("Flat").tag("flat"); Text("Glass").tag("glass") }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                Button("Remove") { customs.remove(at: i); saveCustoms() }.buttonStyle(QuietButtonStyle())
            }
            // The chosen blocks in order; click one to take it out.
            HStack(spacing: 6) {
                ForEach(Array(customs[i].blocks.enumerated()), id: \.offset) { j, b in
                    Button { customs[i].blocks.remove(at: j); saveCustoms() } label: {
                        Text("\(j + 1). \(Self.name(b))").font(.ui(13.5)).padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(Palette.raised)).foregroundStyle(Palette.text)
                    }.buttonStyle(.plain).help("Remove \(Self.name(b))")
                }
                if customs[i].blocks.isEmpty { Text("No blocks yet.").font(.ui(13.5)).foregroundStyle(Palette.text3) }
            }
            if customs[i].blocks.count < 6 {
                HStack(spacing: 6) {
                    Text("Add").font(.ui(13.5)).foregroundStyle(Palette.text3)
                    ForEach(WidgetSnapshot.Custom.blocks.filter { !customs[i].blocks.contains($0.id) }, id: \.id) { b in
                        Button(b.name) { customs[i].blocks.append(b.id); saveCustoms() }.buttonStyle(.plain).font(.ui(13.5)).foregroundStyle(Palette.text2)
                    }
                }
            }
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 8).stroke(Palette.text3.opacity(0.3), lineWidth: 0.5))
    }

    private static func name(_ id: String) -> String { WidgetSnapshot.Custom.blocks.first { $0.id == id }?.name ?? id }
    private func saveCustoms() { model.widgetCustoms = customs }
    private func save() { let t = topic.trimmingCharacters(in: .whitespacesAndNewlines); model.prefs.set(t.isEmpty ? "Stoicism" : t, Prefs.Key.quoteTopic) }
}

/// For people who want full control: the instructions the AI follows when it writes the briefing.
struct AdvancedPane: View {
    @Environment(AppModel.self) private var model
    @Local private var prompt = Prefs.shared.string(Prefs.Key.briefingPrompt).isEmpty ? Intelligence.defaultBriefingPrompt : Prefs.shared.string(Prefs.Key.briefingPrompt)
    private var isDefault: Bool { prompt.trimmingCharacters(in: .whitespacesAndNewlines) == Intelligence.defaultBriefingPrompt }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionLabel("Briefing prompt")
            Text("The instructions the AI follows when it writes your briefing. “{name}” becomes your first name. Your standing instructions from Settings → Briefing are still added, and so are the rules that keep handled mail out and stop the AI from following instructions hidden in emails. Those can't be edited.").font(.ui(14.5)).foregroundStyle(Palette.text2)
            TextEditor(text: $prompt).accessibilityLabel("Briefing prompt").font(.system(size: 14, design: .monospaced)).scrollContentBackground(.hidden).padding(10).frame(minHeight: 220)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
                .onChange(of: prompt) { _, v in
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    model.prefs.set(t == Intelligence.defaultBriefingPrompt ? "" : t, Prefs.Key.briefingPrompt)
                }
            HStack(spacing: 10) {
                Button(model.generatingBriefing ? "Writing…" : "Write the briefing with this prompt") { Task { await model.generateBriefing() } }.buttonStyle(PrimaryButtonStyle()).disabled(model.generatingBriefing || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Reset to default") { prompt = Intelligence.defaultBriefingPrompt }.buttonStyle(QuietButtonStyle()).disabled(isDefault)
                Spacer()
            }
            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("An empty prompt uses the default.").font(.ui(13.5)).foregroundStyle(Palette.text3) }
            Text("\(prompt.count) characters. Longer than 4,000 is cut off.").font(.ui(13)).foregroundStyle(prompt.count > 4000 ? Palette.alertFG : Palette.text3)
        }
    }
}

struct AccountsPane: View {
    @Environment(AppModel.self) private var model
    @Local private var removing: String? = nil
    @Local private var adding = false
    @Local private var tick = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SectionLabel("Mail")
            let emails = model.mail.accountEmails
            if emails.isEmpty || adding {
                Text(emails.isEmpty ? "Connect any mail account with an app password. It takes about a minute and nothing passes through a server of ours." : "Add another account. Its mail joins the same inbox and briefing, and replies go out from the account the mail arrived in.").font(.ui(15.5)).foregroundStyle(Palette.text2)
                MailSetupView { adding = false; tick += 1 }
                if adding { Button("Cancel") { adding = false }.buttonStyle(QuietButtonStyle(compact: true)) }
            }
            if !emails.isEmpty {
                ForEach(Array(emails.enumerated()), id: \.element) { i, e in
                    Row(title: e, detail: kindLabel(e) + (i == 0 && emails.count > 1 ? " · first account" : "") + " · " + (model.mail.lastSync(for: e).map { "last synced \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "not synced yet")) {
                        Button("Remove") { removing = e }.buttonStyle(QuietButtonStyle(compact: true))
                    }
                }
                HStack(spacing: 10) {
                    Button(model.syncingMail ? "Syncing…" : (emails.count > 1 ? "Sync all" : "Sync now")) { Task { await model.syncMail() } }.buttonStyle(QuietButtonStyle()).disabled(model.syncingMail)
                    if !adding { Button("Add another account") { withAnimation(Motion.snappy) { adding = true } }.buttonStyle(QuietButtonStyle()) }
                }
                if !model.mailProgress.isEmpty { Text(model.mailProgress).font(.ui(14)).foregroundStyle(Palette.text2) }
            }
            Hairline().padding(.vertical, 6)
            SectionLabel("System access")
            Row(title: "Calendar", detail: "Shows today's events on the dashboard and in briefings.") { permission(model.calendar.calendarAccess) { _ = await model.calendar.requestCalendar(); model.events = model.calendar.upcoming() } }
            Row(title: "Reminders", detail: "Optional two-way sync for tasks.") { permission(model.calendar.reminderAccess) { _ = await model.calendar.requestReminders() } }
        }
        .id(tick)
        .confirmationDialog("Remove \(removing ?? "this account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove and keep its mail on this Mac") { if let e = removing { model.mail.disconnect(email: e, wipe: false) }; done() }
            Button("Remove and delete its mail from this Mac", role: .destructive) { if let e = removing { model.mail.disconnect(email: e, wipe: true) }; done() }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("Nothing in the mail account itself is changed.") }
    }

    private func done() { removing = nil; model.reloadLocal(); tick += 1 }
    private func kindLabel(_ e: String) -> String { (model.mail.gmail.accountEmail ?? "").lowercased() == e.lowercased() ? "Gmail API" : "IMAP" }

    @ViewBuilder private func permission(_ a: CalendarService.Access, request: @escaping () async -> Void) -> some View {
        switch a {
        case .granted: Text("Allowed").font(.ui(15)).foregroundStyle(Palette.good)
        case .notDetermined: Button("Allow") { Task { await request(); tick += 1 } }.buttonStyle(QuietButtonStyle())
        case .denied: Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!) }.buttonStyle(QuietButtonStyle())
        }
    }
}

struct AIPane: View {
    @Environment(AppModel.self) private var model
    @Local private var provider: ProviderID = .gemini
    @Local private var key = ""
    @Local private var hasKey = false
    @Local private var testing = false
    @Local private var status: (ok: Bool, text: String)? = nil
    @Local private var models: [String] = []
    @Local private var cap = 5.0
    @Local private var fullBodies = true
    @Local private var endpoint = ""
    @Local private var showLog = false
    @Local private var picks: [AIJob: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Bring your own key. everyday. has no servers, so requests go straight from this Mac to the provider you pick.").font(.ui(16)).foregroundStyle(Palette.text2)
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Provider")
                HStack(spacing: 4) { ForEach(ProviderID.allCases) { p in Button(p.title) { select(p) }.buttonStyle(QuietButtonStyle(compact: true, selected: provider == p)) } }
            }
            if provider.needsKey {
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("API key")
                    HStack {
                        Field(title: hasKey ? "A key is saved in the Keychain. Paste a new one to replace it." : "Paste your key", text: $key, secure: true)
                        Button(testing ? "Testing…" : "Save and test") { Task { await saveAndTest() } }.buttonStyle(PrimaryButtonStyle()).disabled(testing || (key.isEmpty && !hasKey)).padding(.top, 18)
                        if hasKey { Button("Remove") { try? model.ai.setAPIKey("", for: provider); hasKey = false; models = []; status = nil }.buttonStyle(QuietButtonStyle()).padding(.top, 18) }
                    }
                    if let s = status { Text(s.text).font(.ui(14.5)).foregroundStyle(s.ok ? Palette.good : Palette.alertFG) }
                    else { HStack(spacing: 8) { Circle().fill(hasKey ? Palette.good : Palette.text3).frame(width: 7, height: 7); Text(hasKey ? "Stored in the macOS Keychain on this Mac. Never written to disk or logs." : "No key yet.").font(.ui(14.5)).foregroundStyle(Palette.text2) } }
                }
            } else if provider == .local {
                Field(title: "OpenAI-compatible endpoint", text: $endpoint).onChange(of: endpoint) { _, v in model.ai.localEndpoint = v }
                Button("Check connection") { Task { await saveAndTest() } }.buttonStyle(QuietButtonStyle())
                if let s = status { Text(s.text).font(.ui(14.5)).foregroundStyle(s.ok ? Palette.good : Palette.alertFG) }
            } else {
                Text(AppleOnDevice.isAvailable ? "Apple Intelligence is available. Requests never leave this Mac. The on-device model is small, so summaries are shorter and less nuanced." : "Apple Intelligence is not available on this Mac.").font(.ui(15.5)).foregroundStyle(Palette.text2)
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack { SectionLabel("Model for each job"); Spacer(); Button("Refresh model list") { Task { models = await model.ai.availableModels() } }.buttonStyle(.plain).font(.ui(13.5)).foregroundStyle(Palette.accentText) }.padding(.bottom, 6)
                ForEach(AIJob.allCases, id: \.self) { job in
                    Row(title: job.title, detail: job == .triage ? "Runs often. A fast, cheap model is enough." : job == .summary ? "Runs when you ask." : "Longer conversations over your mail, news and tasks.") {
                        let current = picks[job] ?? model.ai.model(for: job, provider: provider)
                        if models.isEmpty || provider == .apple {
                            TextField("model", text: Binding(get: { current }, set: { picks[job] = $0; model.ai.setModel($0, for: job, provider: provider) })).accessibilityLabel("Model name").textFieldStyle(.plain).padding(.horizontal, 8).frame(width: 220, height: 30).background(RoundedRectangle(cornerRadius: 6).fill(Palette.raised))
                        } else {
                            Picker("Model", selection: Binding(get: { current }, set: { picks[job] = $0; model.ai.setModel($0, for: job, provider: provider) })) {
                                if !models.contains(current) { Text(current).tag(current) }
                                ForEach(models, id: \.self) { Text($0).tag($0) }
                            }.labelsHidden().frame(width: 240)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 30) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Monthly token cap").font(.ui(16.5))
                    Slider(value: $cap, in: 0...50, step: 1).accessibilityLabel("Monthly token cap").onChange(of: cap) { _, v in model.ai.monthlyTokenCap = v }
                    Text(cap == 0 ? "No cap" : "\(Int(cap)) million tokens. Used this month: \(format(model.ai.tokensUsedThisMonth()))").font(.ui(14)).foregroundStyle(Palette.text2)
                }.frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Send full email bodies to the provider", isOn: $fullBodies).font(.ui(16.5)).onChange(of: fullBodies) { _, v in model.prefs.set(v, Prefs.Key.sendFullBodies) }
                    Text("Off sends only subject lines and short snippets. Signatures and quoted replies are always removed first.").font(.ui(14)).foregroundStyle(Palette.text2)
                    Button("View AI activity log") { showLog = true }.buttonStyle(.plain).font(.ui(15)).foregroundStyle(Palette.accentText)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            provider = model.ai.providerID; hasKey = !(model.ai.apiKey(for: provider) ?? "").isEmpty
            cap = model.ai.monthlyTokenCap; fullBodies = model.prefs.bool(Prefs.Key.sendFullBodies, default: true); endpoint = model.ai.localEndpoint
            Task { models = await model.ai.availableModels() }
        }
        .sheet(isPresented: $showLog) { ActivityLog() }
    }

    private func format(_ n: Int) -> String { n >= 1_000_000 ? String(format: "%.2fM tokens", Double(n) / 1e6) : "\(n / 1000)k tokens" }

    private func select(_ p: ProviderID) {
        provider = p; model.ai.providerID = p; key = ""; status = nil; picks = [:]
        hasKey = !(model.ai.apiKey(for: p) ?? "").isEmpty; models = []
        Task { models = await model.ai.availableModels() }
    }

    private func saveAndTest() async {
        testing = true; defer { testing = false }
        do {
            if !key.isEmpty { try model.ai.setAPIKey(key, for: provider); key = ""; hasKey = true }
            let r = try await model.ai.testConnection()
            status = (true, "Connected. The model replied: \(r)")
            models = await model.ai.availableModels()
        } catch { status = (false, error.localizedDescription) }
    }
}

struct ActivityLog: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Local private var items: [AIActivity] = []
    @Local private var open: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("AI activity").font(.ui(22, .medium)); Spacer(); Button("Clear") { model.ai.clearLog(); items = [] }.buttonStyle(QuietButtonStyle(compact: true)); Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle(compact: true)).keyboardShortcut(.defaultAction) }
            Text("Every request made to your provider, with the exact text that was sent.").font(.ui(14.5)).foregroundStyle(Palette.text2)
            if items.isEmpty { Text("Nothing yet.").font(.ui(15)).foregroundStyle(Palette.text3).padding(.vertical, 30) }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(items) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            Button { open = open == a.id ? nil : a.id } label: {
                                HStack { Text(a.label).font(.ui(15.5, .semibold)); Spacer(); Text("\(a.provider) · \(a.model) · \(a.inputTokens + a.outputTokens) tokens · \(a.date.formatted(date: .abbreviated, time: .shortened))").font(.ui(12.5)).foregroundStyle(Palette.text3) }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            if open == a.id { Text(a.payload).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Palette.text2).textSelection(.enabled).padding(10).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 6).fill(Palette.raised)) }
                        }.padding(.vertical, 9).overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }
        }.padding(24).frame(width: 720, height: 520).background(Palette.window).onAppear { items = model.ai.activityLog() }
    }
}

struct SourcesPane: View {
    @Environment(AppModel.self) private var model
    @Local private var sources: [FeedSource] = []
    @Local private var health: [String: FeedHealth] = [:]
    @Local private var freshness = Prefs.shared.double(Prefs.Key.freshnessHours, default: 48)
    @Local private var outside = Prefs.shared.bool(Prefs.Key.outsideBubble, default: true)
    @Local private var newName = ""
    @Local private var newURL = ""
    @Local private var newCategory: NewsCategory = .technology
    @Local private var adding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Row(title: "Hide stories older than", detail: "Older stories are dropped from your feed.") {
                Stepper(freshness >= 48 ? "\(Int(freshness / 24)) days" : "\(Int(freshness)) hours", value: $freshness, in: 6...168, step: 6).font(.ui(15)).onChange(of: freshness) { _, v in model.prefs.set(v, Prefs.Key.freshnessHours); model.reloadNews() }
            }
            Row(title: "Include outside-your-bubble sources", detail: "About one story in ten comes from a broader mix.") {
                Toggle("Include stories from outside my usual topics", isOn: $outside).labelsHidden().onChange(of: outside) { _, v in model.prefs.set(v, Prefs.Key.outsideBubble); model.reloadNews() }
            }
            HStack(spacing: 8) {
                Button("Import OPML…") { importOPML() }.buttonStyle(QuietButtonStyle(compact: true))
                Button("Export OPML…") { exportOPML() }.buttonStyle(QuietButtonStyle(compact: true))
                Text("Move your sources to or from other feed readers.").font(.ui(13.5)).foregroundStyle(Palette.text3)
            }
            SectionLabel("Add a source").padding(.top, 8)
            HStack(alignment: .bottom, spacing: 8) {
                Field(title: "Name", text: $newName)
                Field(title: "Feed URL (RSS or Atom)", text: $newURL)
                Picker("Category for the new source", selection: $newCategory) { ForEach(NewsCategory.allCases) { Text($0.title).tag($0) } }.labelsHidden().frame(width: 130)
                Button(adding ? "Checking…" : "Add") { Task { await add() } }.buttonStyle(PrimaryButtonStyle()).disabled(newURL.isEmpty || newName.isEmpty || adding)
            }
            SectionLabel("Sources").padding(.top, 8)
            ForEach(sources) { s in
                let h = health[s.url]
                HStack(spacing: 12) {
                    Toggle("Enable \(s.name)", isOn: Binding(get: { s.enabled }, set: { v in var x = s; x.enabled = v; model.news.save(source: x); load() })).labelsHidden()
                    VStack(alignment: .leading, spacing: 0) {
                        Text(s.name).font(.ui(16))
                        Text(h?.lastError.map { "Problem: \($0)" } ?? (h?.lastFetched != nil ? "\(h?.itemCount ?? 0) items, checked \(h!.lastFetched!.relativeShort)" : "Not fetched yet") + (s.outsideBubble ? " · outside your bubble" : "")).font(.ui(13)).foregroundStyle(h?.lastError != nil ? Palette.alertFG : Palette.text3).lineLimit(1)
                    }
                    Spacer()
                    Picker("Trust for \(s.name)", selection: Binding(get: { s.trust }, set: { v in var x = s; x.trust = v; model.news.save(source: x); load() })) { Text("Low trust").tag(1); Text("Standard").tag(2); Text("High trust").tag(3) }.labelsHidden().frame(width: 120)
                    Button { model.news.remove(source: s); load() } label: { Image(systemName: "trash") }.buttonStyle(QuietButtonStyle(compact: true)).accessibilityLabel("Remove \(s.name)")
                }.padding(.vertical, 6).overlay(alignment: .bottom) { Hairline() }
            }
        }.onAppear { load() }
    }

    private func load() { sources = model.news.sources(); health = model.news.health() }

    private func exportOPML() {
        let p = NSSavePanel(); p.nameFieldStringValue = "everyday-sources.opml"; p.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml]
        if p.runModal() == .OK, let u = p.url { do { try OPML.export(model.news.sources()).write(to: u, atomically: true, encoding: .utf8); model.say("Exported \(sources.count) sources.") } catch { model.fail(error, "Export") } }
    }
    private func importOPML() {
        let p = NSOpenPanel(); p.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard p.runModal() == .OK, let u = p.url, let data = try? Data(contentsOf: u) else { return }
        let found = OPML.parse(data)
        let existing = Set(model.news.sources().map(\.url))
        let new = found.filter { !existing.contains($0.url) }
        for s in new { model.news.save(source: s) }
        load()
        model.say(found.isEmpty ? "No feeds found in that file." : "Added \(new.count) new source\(new.count == 1 ? "" : "s") (\(found.count - new.count) already there).", error: found.isEmpty)
        if !new.isEmpty { Task { await model.refreshNews(silent: true, force: true) } }
    }

    private func add() async {
        adding = true; defer { adding = false }
        guard let url = URL(string: newURL.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { model.say("That is not a valid web address.", error: true); return }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard !FeedParser.parse(data).isEmpty else { model.say("No articles found at that address. Is it an RSS or Atom feed?", error: true); return }
            model.news.save(source: FeedSource(name: newName, url: url.absoluteString, categories: [newCategory], trust: 2))
            newName = ""; newURL = ""; load()
            Task { await model.refreshNews(silent: true, force: true) }
            model.say("Source added.")
        } catch { model.fail(error, "Source") }
    }
}

struct InterestsPane: View {
    @Environment(AppModel.self) private var model
    @Local private var cats: Set<NewsCategory> = []
    @Local private var retrain = false
    @Local private var deck: [Article] = []
    @Local private var confirmReset = false
    @Local private var tick = 0
    @Local private var newTopic = ""
    @Local private var topics: [String] = Prefs.shared.strings(Prefs.Key.followedTopics)

    private func addTopic() {
        let t = newTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        newTopic = ""
        guard !t.isEmpty, !topics.contains(where: { $0.lowercased() == t.lowercased() }) else { return }
        topics.append(t); saveTopics()
    }
    private func saveTopics() { model.prefs.set(topics, Prefs.Key.followedTopics); model.reloadNews() }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("everyday. learns what you like from the categories you pick, the stories you swipe on, and what you read or save. It all stays on this Mac.").font(.ui(15.5)).foregroundStyle(Palette.text2)
            SectionLabel("What it has learned")
            let top = model.interests.topInterests(8).filter { $0.1 > 0 }
            if top.isEmpty { Text("Nothing yet. Swipe through some stories to teach it.").font(.ui(15)).foregroundStyle(Palette.text3) }
            let maxV = top.map(\.1).max() ?? 1
            ForEach(top, id: \.0) { k, v in
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(NewsCategory(rawValue: k)?.title ?? k).font(.ui(16)); Spacer(); Text(v > maxV * 0.66 ? "High" : v > maxV * 0.33 ? "Medium" : "Low").font(.ui(14)).foregroundStyle(Palette.text2) }
                    GeometryReader { g in ZStack(alignment: .leading) { Capsule().fill(Palette.control); Capsule().fill(Palette.accent).frame(width: g.size.width * CGFloat(max(0.05, v / maxV))) } }.frame(height: 4)
                }
            }
            Text("\(model.interests.snapshot.reactionCount) reactions recorded.").font(.ui(14)).foregroundStyle(Palette.text3)
            Hairline()
            SectionLabel("Your own topics")
            Text("Follow anything by name, like “Formula 1”, “Cairns” or “Rust”. Stories that mention it rise to the top, and it gets its own tab in News.").font(.ui(14)).foregroundStyle(Palette.text3)
            HStack(spacing: 8) {
                TextField("Add a topic, then press Return", text: $newTopic).accessibilityLabel("Follow a topic").textFieldStyle(.plain).font(.ui(15)).padding(.horizontal, 10).frame(height: 32).background(RoundedRectangle(cornerRadius: 7).fill(Palette.raised)).onSubmit { addTopic() }
                Button("Follow") { addTopic() }.buttonStyle(QuietButtonStyle()).disabled(newTopic.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !topics.isEmpty {
                FlowLayout(spacing: 8) {
                    ForEach(topics, id: \.self) { t in
                        HStack(spacing: 6) { Text(t).font(.ui(14)); Button { topics.removeAll { $0 == t }; saveTopics() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.buttonStyle(.plain).accessibilityLabel("Stop following \(t)") }
                            .padding(.horizontal, 10).padding(.vertical, 5).background(Capsule().fill(Palette.control))
                    }
                }
            }
            Hairline()
            SectionLabel("Categories")
            CategoryPicker(selected: $cats).onChange(of: cats) { _, v in model.prefs.set(v.map(\.rawValue), Prefs.Key.categories); model.interests.seed(categories: []) }
            HStack {
                Button("Retrain with a swipe deck") { startRetrain() }.buttonStyle(PrimaryButtonStyle())
                Button("Export profile") { export() }.buttonStyle(QuietButtonStyle())
                Button("Import profile") { importProfile() }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Reset everything learned") { confirmReset = true }.buttonStyle(QuietButtonStyle())
            }
        }
        .id(tick)
        .onAppear { cats = Set(model.prefs.strings(Prefs.Key.categories).compactMap(NewsCategory.init(rawValue:))) }
        .confirmationDialog("Reset what everyday. has learned?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { model.interests.reset(); model.interests.seed(categories: Array(cats)); model.reloadNews(); tick += 1 }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your categories are kept. Swipe history and reading signals are cleared.") }
        .sheet(isPresented: $retrain) {
            VStack { SwipeDeck(cards: deck) { retrain = false; tick += 1; model.reloadNews() }.padding(24); Button("Close") { retrain = false; tick += 1 }.buttonStyle(QuietButtonStyle()).padding(.bottom, 20) }
                .frame(width: 560, height: 640).background(Palette.window)
        }
    }

    private func startRetrain() {
        let chosen = cats.isEmpty ? NewsCategory.allCases : Array(cats)
        Task { await model.refreshNews(silent: true); deck = model.news.swipeDeck(categories: chosen, count: 20); if deck.isEmpty { model.say("No stories available to swipe on yet.", error: true) } else { retrain = true } }
    }
    private func export() {
        guard let data = model.interests.exportJSON() else { return }
        let p = NSSavePanel(); p.nameFieldStringValue = "everyday-interests.json"; p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url { do { try data.write(to: u); model.say("Profile exported.") } catch { model.fail(error, "Export") } }
    }
    private func importProfile() {
        let p = NSOpenPanel(); p.allowedContentTypes = [.json]
        if p.runModal() == .OK, let u = p.url { do { try model.interests.importJSON(Data(contentsOf: u)); model.reloadNews(); tick += 1; model.say("Profile imported.") } catch { model.fail(error, "Import") } }
    }
}

struct PrivacyPane: View {
    @Environment(AppModel.self) private var model
    @Local private var confirmWipe = false
    var body: some View {
        let db = model.db
        VStack(alignment: .leading, spacing: 18) {
            Text("everyday. has no servers, no accounts and no analytics. This is everything that leaves your Mac.").font(.ui(16)).foregroundStyle(Palette.text2)
            Row(title: "Gmail", detail: "Mail is fetched from Google directly. Sent, archived or trashed only after you approve.") { Text("google.com").font(.ui(14)).foregroundStyle(Palette.text3) }
            Row(title: "News sources", detail: "Each feed and article page you open is fetched from its publisher.") { Text("publishers").font(.ui(14)).foregroundStyle(Palette.text3) }
            Row(title: "Weather", detail: "Only your city name and its coordinates go to Open-Meteo.") { Text("open-meteo.com").font(.ui(14)).foregroundStyle(Palette.text3) }
            Row(title: "AI provider", detail: "Only what you see in the AI activity log, to the provider you chose.") { Text(model.ai.providerID.title).font(.ui(14)).foregroundStyle(Palette.text3) }
            SectionLabel("Stored on this Mac").padding(.top, 8)
            ForEach([("Emails", "email"), ("Mail sorting results", "triage"), ("News articles", "article"), ("Tasks", "task"), ("AI activity entries", "aiLog")], id: \.1) { t, k in
                Row(title: t) { Text("\((try? db.count(k)) ?? 0)").font(.ui(15)).foregroundStyle(Palette.text2) }
            }
            Text("Keys and sign-in tokens are held in the macOS Keychain, not in this database.").font(.ui(14)).foregroundStyle(Palette.text3)
            HStack {
                Button("Show data folder") { if let u = db.url?.deletingLastPathComponent() { NSWorkspace.shared.activateFileViewerSelecting([u]) } }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Delete all data and sign out…") { confirmWipe = true }.buttonStyle(QuietButtonStyle())
            }
        }.confirmationDialog("Delete everything?", isPresented: $confirmWipe, titleVisibility: .visible) {
            Button("Delete all data", role: .destructive) { model.wipeAll() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Removes local mail, news, tasks, preferences, AI keys and the Gmail sign-in from this Mac. Your Gmail account itself is untouched.") }
    }
}

struct NotificationsPane: View {
    @Environment(AppModel.self) private var model
    @Local private var on = Prefs.shared.bool(Prefs.Key.notifications, default: true)
    @Local private var morning = Prefs.shared.bool(Prefs.Key.briefingNotify, default: false)
    @Local private var hour = Int(Prefs.shared.double(Prefs.Key.briefingHour, default: 7))
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Row(title: "Morning briefing", detail: "Writes your briefing at this time and sends a notification with the first lines. everyday. must be running (it can live in the menu bar).") {
                HStack(spacing: 10) {
                    if morning { Picker("Briefing hour", selection: $hour) { ForEach(4..<13, id: \.self) { h in Text(String(format: "%d:00 %@", h > 12 ? h - 12 : h, h < 12 ? "am" : "pm")).tag(h) } }.labelsHidden().frame(width: 100).onChange(of: hour) { _, v in model.prefs.set(Double(v), Prefs.Key.briefingHour) } }
                    Toggle("Morning briefing notification", isOn: $morning).labelsHidden().onChange(of: morning) { _, v in model.prefs.set(v, Prefs.Key.briefingNotify); if v { model.requestNotificationPermission(); model.prefs.set("", Prefs.Key.briefingLastNotified) } }
                }
            }
            Row(title: "Task reminders", detail: "A notification when a task with a due time comes up.") {
                Toggle("Task reminders", isOn: $on).labelsHidden().onChange(of: on) { _, v in model.prefs.set(v, Prefs.Key.notifications); if v { model.requestNotificationPermission() }; model.scheduleTaskNotifications() }
            }
            Row(title: "System permission", detail: "macOS must allow notifications for everyday.") {
                Button("Open Notification settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!) }.buttonStyle(QuietButtonStyle())
            }
            Text("The menu bar item shows how many priority emails and due tasks need you.").font(.ui(14.5)).foregroundStyle(Palette.text3).padding(.top, 8)
        }
    }
}

struct AppearancePane: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dark is the default. Light uses the same warm palette.").font(.ui(16)).foregroundStyle(Palette.text2)
            HStack(spacing: 6) {
                ForEach([("dark", "Dark"), ("light", "Light"), ("system", "Match system")], id: \.0) { id, t in Button(t) { model.appearance = id }.buttonStyle(QuietButtonStyle(selected: model.appearance == id)) }
            }
            Hairline().padding(.vertical, 4)
            SectionLabel("Skim reading")
            Row(title: "Highlight key points", detail: "Briefings and summaries colour what matters. Rewrite a briefing to add highlights to an older one.") {
                Toggle("Skim highlights", isOn: Bindable(model).skim).labelsHidden()
            }
            SkimLegend().padding(.vertical, 4)
            Row(title: "Sans-serif summaries", detail: "Use the system sans for briefings and summaries instead of the reading serif.") {
                Toggle("Use sans-serif for highlights", isOn: Bindable(model).skimSans).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Preview").font(.ui(12, .semibold)).tracking(1.2).foregroundStyle(Palette.text3)
                SkimBody(text: "<<u|Final notice>>: <<a|sign the lease renewal>> by <<d|Friday 6 November>>. <<p|Oscar Fox>> is waiting on a reply about the roadmap sync, and <<m|$1,240>> is due to <<p|Studio Kite>> by <<d|12 November>>. Rain clears by noon in <<l|Cairns>>, heading to <<n|31°C>>.", size: 17)
                    .padding(16).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
            }
        }
    }
}
