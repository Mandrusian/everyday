import SwiftUI
import EverydayCore

/// A row in the inbox list standing for several automated emails from one sender.
struct BundleRowView: View {
    @Environment(AppModel.self) private var model
    let bundle: MailBundle
    let selected: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if bundle.unread > 0 { Circle().fill(Palette.accent).frame(width: 7, height: 7) }
                Text(bundle.title).font(.ui(16, bundle.unread > 0 ? .semibold : .regular)).lineLimit(1)
                Text("\(bundle.count) emails").font(.ui(12.5)).foregroundStyle(Palette.text2).padding(.horizontal, 6).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 4).fill(Palette.control))
                Spacer()
                Text(bundle.latest.relativeShort).font(.ui(13)).foregroundStyle(Palette.text3)
            }
            Text(model.mail.cachedBundleSummary(bundle).map { SkimMarkup.strip($0) } ?? bundle.rows.prefix(3).map(\.message.subject).joined(separator: " · "))
                .font(.ui(14.5)).foregroundStyle(Palette.text2).lineLimit(2)
            HStack(spacing: 6) {
                if let c = bundle.category { Chip(text: c.title, kind: bundle.hasUrgent ? .deadline : .quiet) }
                Chip(text: "Bundle", kind: .quiet)
            }.padding(.top, 3)
        }
        .padding(.horizontal, 20).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Palette.selected : .clear)
        .overlay(alignment: .bottom) { Hairline() }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine).accessibilityAddTraits(.isButton)
    }
}

/// One summary for the whole bundle, with every original email listed underneath as a source.
struct BundleView: View {
    @Environment(AppModel.self) private var model
    let bundle: MailBundle
    @Local private var summary: String?
    @Local private var summarizing = false
    @Local private var confirmArchive = false

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(title: "\(bundle.title)", subtitle: "\(bundle.count) emails") {
                Button("That was me") { model.markHandled(bundle.rows.map { $0.message.threadId }) }.buttonStyle(QuietButtonStyle(compact: true)).help("Stop flagging these. Nothing changes in your mail account.")
                Button("Archive all") { confirmArchive = true }.buttonStyle(QuietButtonStyle(compact: true))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { SectionLabel("Summary"); Spacer()
                            if summary != nil { Button("Refresh") { Task { await summarize(force: true) } }.buttonStyle(.plain).font(.ui(13.5)).foregroundStyle(Palette.accentText).disabled(summarizing || !model.ai.isConfigured) } }
                        if summarizing { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading \(bundle.count) emails…").font(.ui(15)).foregroundStyle(Palette.text2) } }
                        else if let s = summary { SkimBody(text: s, size: 16.5, smooth: true) }
                        else if model.ai.isConfigured { Button("Summarize these \(bundle.count) emails") { Task { await summarize() } }.buttonStyle(QuietButtonStyle(compact: true)) }
                        else { Text("Add an AI provider key in Settings to get a summary.").font(.ui(15)).foregroundStyle(Palette.text2) }
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))

                    VStack(alignment: .leading, spacing: 0) {
                        SectionLabel("Sources").padding(.bottom, 6)
                        ForEach(bundle.rows) { r in
                            Button { model.returnBundleID = bundle.id; model.selectedThread = r.message.threadId } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Circle().fill(r.message.isUnread ? Palette.accent : .clear).frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(r.message.subject).font(.ui(15.5, r.message.isUnread ? .semibold : .regular)).foregroundStyle(Palette.text).lineLimit(1)
                                        Text(r.triage?.summary.isEmpty == false ? r.triage!.summary : r.message.snippet).font(.ui(13.5)).foregroundStyle(Palette.text2).lineLimit(1)
                                    }
                                    Spacer(minLength: 8)
                                    Text(r.message.date.formatted(date: .abbreviated, time: .shortened)).font(.ui(13)).foregroundStyle(Palette.text3)
                                    Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Palette.text3)
                                }.padding(.vertical, 10).contentShape(Rectangle()).overlay(alignment: .bottom) { Hairline() }
                            }.buttonStyle(.plain).accessibilityLabel("Open \(r.message.subject)")
                        }
                    }
                }.padding(.horizontal, 28).padding(.vertical, 20).frame(maxWidth: 760, alignment: .leading).frame(maxWidth: .infinity)
            }
        }
        .task {
            summary = model.mail.cachedBundleSummary(bundle)
            if summary == nil, model.ai.isConfigured { await summarize() }
        }
        .confirmationDialog("Archive all \(bundle.count) emails from \(bundle.title)?", isPresented: $confirmArchive, titleVisibility: .visible) {
            Button("Archive all") { model.archiveThreads(bundle.rows.map { $0.message.threadId }); model.selectedBundleID = nil }
            Button("Cancel", role: .cancel) {}
        } message: { Text("They leave your inbox but stay in All Mail.") }
    }

    private func summarize(force: Bool = false) async {
        summarizing = true; defer { summarizing = false }
        do { summary = try await model.mail.bundleSummary(bundle, regenerate: force) } catch { model.fail(error, "Summary") }
    }
}
