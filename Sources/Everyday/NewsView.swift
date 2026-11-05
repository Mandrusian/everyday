import SwiftUI
import AppKit
import EverydayCore

struct NewsView: View {
    @Environment(AppModel.self) private var model
    @Local private var category: NewsCategory?

    private var list: [Story] {
        guard let c = category else { return model.stories }
        return model.news.stories(category: c, limit: 80)
    }
    private var selected: Story? { list.first { $0.id == model.selectedStoryID } ?? model.stories.first { $0.id == model.selectedStoryID } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                PaneHeader(title: "For you") {
                    if model.refreshingNews { ProgressView().controlSize(.small) }
                    Button { Task { await model.refreshNews(force: true) } } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(QuietButtonStyle(compact: true)).accessibilityLabel("Refresh news").help("Refresh news")
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button("All") { category = nil }.buttonStyle(QuietButtonStyle(compact: true, selected: category == nil))
                        ForEach(chosen, id: \.self) { c in Button(c.title) { category = c }.buttonStyle(QuietButtonStyle(compact: true, selected: category == c)) }
                    }.padding(.horizontal, 20).padding(.vertical, 12)
                }
                Hairline()
                if list.isEmpty {
                    EmptyState(title: model.refreshingNews ? "Fetching the news" : "No stories", message: model.refreshingNews ? "Reading your sources…" : "Nothing recent matches. Try refreshing, or add sources in Settings.")
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(list.enumerated()), id: \.element.id) { i, s in StoryRow(story: s, selected: s.id == model.selectedStoryID).onTapGesture { model.selectedStoryID = s.id }.entrance(i) }
                        }
                    }
                }
            }.frame(width: 350)
            Hairline(vertical: true)
            Group {
                if let s = selected { ReaderView(story: s).id(s.id) }
                else { EmptyState(title: "Pick a story", message: "Open one to read it here, get a summary and see why it matters.") }
            }.frame(maxWidth: .infinity)
        }
        .onAppear { if model.selectedStoryID == nil { model.selectedStoryID = model.stories.first?.id } }
    }

    private var chosen: [NewsCategory] {
        let ids = model.prefs.strings(Prefs.Key.categories).compactMap(NewsCategory.init(rawValue:))
        return ids.isEmpty ? NewsCategory.allCases : ids
    }
}

struct StoryRow: View {
    let story: Story
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(story.categories.first?.title ?? "News"), \(story.sources.count) source\(story.sources.count == 1 ? "" : "s"), \(story.lead.published.ageShort)").font(.ui(13)).foregroundStyle(Palette.text3)
            Text(story.lead.title).font(.ui(17, .medium)).lineLimit(3).multilineTextAlignment(.leading).foregroundStyle(Palette.text)
            Text(story.lead.source).font(.ui(13.5)).foregroundStyle(Palette.text2)
        }
        .padding(.horizontal, 20).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.selected : .clear).overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle()).accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}

@MainActor @Observable
final class ReaderState {
    var extracted: ExtractedArticle?
    var loading = true
    var failed = false
    var ai: ArticleAI?
    var summarizing = false
    var qa: [ChatMessage] = []
    var asking = false
    var question = ""
    var text: String { extracted?.text.isEmpty == false ? extracted!.text : "" }
}

struct ReaderView: View {
    @Environment(AppModel.self) private var model
    let story: Story
    @Local private var state = ReaderState()
    @Local private var saved = false

    private var a: Article { story.lead }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("\(a.source) · \(a.published.formatted(date: .abbreviated, time: .shortened))").font(.ui(14)).foregroundStyle(Palette.text3).lineLimit(1)
                Spacer()
                Button { Task { await summarize() } } label: { Text(state.ai == nil ? "Summarize" : "Summarized") }.buttonStyle(PrimaryButtonStyle(compact: true)).disabled(state.summarizing || state.ai != nil)
                Button(saved ? "Saved" : "Save") { model.toggleSaved(a); saved.toggle() }.buttonStyle(QuietButtonStyle(compact: true, selected: saved))
                ListenButton(owner: a.id, chunks: { [a.title] + (state.extracted?.paragraphs.isEmpty == false ? state.extracted!.paragraphs : [a.summary]) })
                Menu {
                    Button("More like this") { model.react(a, .like); model.say("Noted: more like this.") }
                    Button("Less like this") { model.react(a, .dislike); model.say("Noted: less like this.") }
                    Divider()
                    Button("Open in browser") { if let u = URL(string: a.link) { NSWorkspace.shared.open(u) } }
                    Button("Copy link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(a.link, forType: .string) }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.button).buttonStyle(QuietButtonStyle(compact: true)).menuIndicator(.hidden).fixedSize().accessibilityLabel("More actions")
            }.padding(.horizontal, 28).frame(height: 52).overlay(alignment: .bottom) { Hairline() }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text(a.title).font(.serif(36, .regular)).lineSpacing(2).foregroundStyle(Palette.text).textSelection(.enabled)
                    if let img = state.extracted?.imageURL ?? a.imageURL, let u = URL(string: img) {
                        AsyncImage(url: u) { p in if let i = p.image { i.resizable().scaledToFill() } else { Rectangle().fill(Palette.raised) } }
                            .frame(maxWidth: .infinity).frame(height: 280).clipShape(RoundedRectangle(cornerRadius: 8)).accessibilityHidden(true)
                    }
                    aiCard
                    if state.loading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading the article…").font(.ui(15)).foregroundStyle(Palette.text2) } }
                    else if state.failed || state.extracted?.paragraphs.isEmpty != false {
                        Text(a.summary.isEmpty ? "This page could not be read here." : a.summary).font(.serif(19)).lineSpacing(6)
                        Text("The full article may be behind a paywall or built in a way everyday. cannot read.").font(.ui(14.5)).foregroundStyle(Palette.text2)
                        Button("Open in browser") { if let u = URL(string: a.link) { NSWorkspace.shared.open(u) } }.buttonStyle(QuietButtonStyle())
                    } else {
                        ForEach(Array((state.extracted?.paragraphs ?? []).enumerated()), id: \.offset) { i, p in
                            let speaking = SpeechService.shared.owner == a.id && SpeechService.shared.currentChunk == i + 1
                            Text(p).font(.serif(19.5)).lineSpacing(7).foregroundStyle(speaking ? Palette.text : (SpeechService.shared.owner == a.id ? Palette.text2 : Palette.text)).textSelection(.enabled)
                                .padding(.horizontal, speaking ? 12 : 0).padding(.vertical, speaking ? 6 : 0).background(RoundedRectangle(cornerRadius: 8).fill(speaking ? Palette.selected : .clear))
                                .padding(.horizontal, speaking ? -12 : 0).animation(Motion.gentle, value: speaking)
                        }
                    }
                    sourcesBlock
                    qaBlock
                }.padding(.horizontal, 40).padding(.vertical, 28).frame(maxWidth: 720, alignment: .leading).frame(maxWidth: .infinity)
            }
            askBar
        }
        .task {
            saved = model.news.isSaved(a.id)
            state.ai = model.news.cachedAI(a.id)
            do { state.extracted = try await ArticleExtractor.fetch(a.link) } catch { state.failed = true }
            state.loading = false
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            if !Task.isCancelled { model.news.interests.record(a, reaction: 0.25) }
        }
    }

    @ViewBuilder private var aiCard: some View {
        if state.summarizing {
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Summarizing…").font(.ui(15)).foregroundStyle(Palette.text2) }
        } else if let ai = state.ai {
            VStack(alignment: .leading, spacing: 10) {
                SectionLabel("Summary")
                SkimBody(text: ai.summary, size: 17)
                if !ai.whyItMatters.isEmpty { SectionLabel("Why it matters").padding(.top, 4); SkimBody(text: ai.whyItMatters, size: 17) }
                Text("Written by \(model.ai.providerID.title) from the article text. Check the source for details.").font(.ui(13)).foregroundStyle(Palette.text3)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
        }
    }

    @ViewBuilder private var sourcesBlock: some View {
        var seenSources = Set<String>()
        let all = ([story.lead] + story.others).filter { seenSources.insert($0.source).inserted }
        VStack(alignment: .leading, spacing: 6) {
            Hairline()
            SectionLabel(all.count > 1 ? "Also reported by" : "Source").padding(.top, 6)
            ForEach(all, id: \.id) { x in
                Button { if let u = URL(string: x.link) { NSWorkspace.shared.open(u) } } label: {
                    HStack { Text(x.source).font(.ui(15, .semibold)); Text(x.title).font(.ui(14.5)).foregroundStyle(Palette.text2).lineLimit(1); Spacer(); Image(systemName: "arrow.up.right").font(.system(size: 11)).foregroundStyle(Palette.text3) }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var qaBlock: some View {
        if !state.qa.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Hairline()
                ForEach(state.qa) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.role == .user ? "You" : "everyday.").font(.ui(12.5, .semibold)).foregroundStyle(m.role == .user ? Palette.text3 : Palette.accentText)
                        Text(m.text.isEmpty ? "…" : m.text).font(.ui(16.5)).lineSpacing(4).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            TextField("Ask about this article", text: $state.question).accessibilityLabel("Ask about this article").textFieldStyle(.plain).font(.ui(16)).padding(.horizontal, 14).frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised)).onSubmit { Task { await ask() } }
            Button("Ask") { Task { await ask() } }.buttonStyle(QuietButtonStyle()).disabled(state.asking || state.question.trimmingCharacters(in: .whitespaces).isEmpty)
        }.padding(.horizontal, 28).padding(.vertical, 12).overlay(alignment: .top) { Hairline() }
    }

    private func summarize() async {
        guard model.ai.isConfigured else { model.say("Add an AI provider key in Settings first.", error: true); return }
        state.summarizing = true; defer { state.summarizing = false }
        let body = state.text.isEmpty ? a.summary : state.text
        do { let r = try await model.intel.summarizeArticle(a, text: body); state.ai = r; model.news.cacheAI(r) } catch { model.fail(error, "Summary") }
    }

    private func ask() async {
        let q = state.question.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        guard model.ai.isConfigured else { model.say("Add an AI provider key in Settings first.", error: true); return }
        state.question = ""; state.asking = true; defer { state.asking = false }
        let history = state.qa
        state.qa.append(ChatMessage(role: .user, text: q))
        var reply = ChatMessage(role: .assistant, text: "")
        state.qa.append(reply)
        do {
            for try await chunk in model.intel.askAboutArticle(a, text: state.text.isEmpty ? a.summary : state.text, history: history, question: q) {
                reply.text += chunk
                if let i = state.qa.lastIndex(where: { $0.id == reply.id }) { state.qa[i] = reply }
            }
        } catch { model.fail(error, "Ask"); if reply.text.isEmpty { state.qa.removeAll { $0.id == reply.id } } }
    }
}

struct SavedView: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "Saved")
            if model.savedArticles.isEmpty {
                EmptyState(title: "Nothing saved", message: "Press Save while reading a story and it will wait for you here.")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.savedArticles) { a in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(a.source), \(a.published.relativeShort)").font(.ui(13)).foregroundStyle(Palette.text3)
                                    Text(a.title).font(.ui(18, .medium)).multilineTextAlignment(.leading)
                                    if !a.summary.isEmpty { Text(a.summary).font(.ui(14.5)).foregroundStyle(Palette.text2).lineLimit(2) }
                                }
                                Spacer()
                                Button("Open") { model.selectedStoryID = a.id; if !model.stories.contains(where: { $0.id == a.id }) { model.stories.insert(Story(lead: a, others: [], score: 0), at: 0) }; model.section = .news }.buttonStyle(QuietButtonStyle(compact: true))
                                Button("Remove") { model.toggleSaved(a) }.buttonStyle(QuietButtonStyle(compact: true))
                            }.padding(.horizontal, 28).padding(.vertical, 14).overlay(alignment: .bottom) { Hairline() }
                        }
                    }
                }
            }
        }
    }
}
