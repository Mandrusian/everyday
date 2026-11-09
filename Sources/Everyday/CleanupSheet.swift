import SwiftUI
import EverydayCore

/// Tell the AI what to clear out, approve its plan, then review the exact list before anything moves.
/// Three steps, and nothing changes until the last button: ask → "Do you approve this plan?" → tick the emails → Move to Trash / Archive.
struct CleanupSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    enum Step { case ask, plan, review }
    @Local private var step: Step = .ask
    @Local private var request = ""
    @Local private var thinking = false
    @Local private var problem: String? = nil
    @Local private var plan: CleanupPlan? = nil
    @Local private var off: Set<String> = []
    @Local private var remember = false
    @Local private var showHeld = false

    /// Opened from a saved cleanup: skip straight to the plan.
    var preset: CleanupPlan? = nil

    private var chosen: [String] { (plan?.rows ?? []).map(\.message.threadId).filter { !off.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .ask: askStep
            case .plan: planStep
            case .review: reviewStep
            }
        }
        .padding(24).frame(width: 580, height: 600, alignment: .topLeading).background(Palette.window)
        .animation(Motion.snappy, value: step)
        .onAppear { if let p = preset { plan = p; request = p.query.summary; step = .plan } }
    }

    // MARK: 1. Ask

    private var askStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Clear out your inbox").font(.serif(26))
            Text("Say which emails to delete or archive. I'll show you my plan and the exact list first. Nothing changes until you approve both.").font(.ui(15)).foregroundStyle(Palette.text2)
            TextField("For example: delete LinkedIn notifications older than a week", text: $request, axis: .vertical)
                .textFieldStyle(.plain).font(.ui(16)).lineLimit(2...4).padding(12)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.raised))
                .onSubmit { Task { await makePlan() } }
                .disabled(thinking)
            FlowLayout(spacing: 8) {
                ForEach(["Delete CI failure emails", "Archive newsletters older than a month", "Delete promotions I never opened"], id: \.self) { ex in
                    Button(ex) { request = ex }.buttonStyle(QuietButtonStyle(compact: true))
                }
            }
            if let problem { Text(problem).font(.ui(14.5)).foregroundStyle(Palette.alertFG).transition(.opacity) }
            if !model.ai.isConfigured { Text("Add an AI provider key in Settings to use this.").font(.ui(14.5)).foregroundStyle(Palette.text3) }
            Spacer()
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Spacer()
                if thinking { ProgressView().controlSize(.small) }
                Button(thinking ? "Making a plan…" : "Make a plan") { Task { await makePlan() } }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(thinking || request.trimmingCharacters(in: .whitespacesAndNewlines).count < 4 || !model.ai.isConfigured)
            }
        }
    }

    private func makePlan() async {
        let text = request.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 4, !thinking else { return }
        thinking = true; problem = nil
        defer { thinking = false }
        do {
            let q = try await model.mail.understandCleanup(text)
            let p = model.mail.cleanupPlan(q)
            plan = p; off = []; remember = false; showHeld = false
            step = .plan
        } catch {
            problem = (error as? CleanupError)?.errorDescription ?? "Couldn't make a plan: \(error.localizedDescription)"
        }
    }

    // MARK: 2. Approve the plan

    @ViewBuilder private var planStep: some View {
        if let p = plan {
            Text("Here's my plan").font(.serif(26))
            if !p.query.summary.isEmpty { Text(p.query.summary).font(.ui(15)).foregroundStyle(Palette.text2) }
            VStack(alignment: .leading, spacing: 8) {
                Text(p.query.plainDescription).font(.ui(16.5, .semibold)).fixedSize(horizontal: false, vertical: true)
                Text(countLine(p)).font(.ui(14.5)).foregroundStyle(Palette.text2)
                if !p.protected.isEmpty {
                    Text("I'll leave \(p.protected.count) alone because \(p.protected.count == 1 ? "it looks" : "they look") important: starred, a VIP, a deadline or someone waiting on you.").font(.ui(14)).foregroundStyle(Palette.text3)
                }
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.raised))
            if !p.rows.isEmpty {
                Text("For example").font(.ui(13, .semibold)).foregroundStyle(Palette.text3)
                VStack(spacing: 0) { ForEach(p.rows.prefix(5)) { r in sample(r) } }
            }
            Spacer()
            if p.rows.isEmpty {
                Text("Nothing in your inbox matches. Try different words.").font(.ui(15)).foregroundStyle(Palette.text2)
                HStack { Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle()); Spacer(); Button("Change the request") { step = .ask }.buttonStyle(PrimaryButtonStyle()) }
            } else {
                Text("Do you approve this plan?").font(.ui(16, .semibold))
                HStack {
                    Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                    Button("No, change it") { step = .ask }.buttonStyle(QuietButtonStyle())
                    Spacer()
                    Button("Yes, show me the list") { step = .review }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func countLine(_ p: CleanupPlan) -> String {
        let n = p.rows.count
        let base = n == 1 ? "1 conversation matches." : "\(n) conversations match."
        return n >= MailService.cleanupLimit ? base + " That's the most I'll do at once." : base
    }

    private func sample(_ r: MailRow) -> some View {
        HStack(spacing: 10) {
            Text(r.message.fromName).font(.ui(14, .semibold)).lineLimit(1).frame(width: 150, alignment: .leading)
            Text(r.message.subject).font(.ui(14)).foregroundStyle(Palette.text2).lineLimit(1)
            Spacer(minLength: 6)
            Text(r.message.date.relativeShort).font(.ui(12.5)).foregroundStyle(Palette.text3).fixedSize()
        }.padding(.vertical, 7).overlay(alignment: .bottom) { Hairline() }
    }

    // MARK: 3. Review the list, then act

    @ViewBuilder private var reviewStep: some View {
        if let p = plan {
            let trash = p.query.action == .trash
            Text(trash ? "Move \(chosen.count) of \(p.rows.count) to Trash?" : "Archive \(chosen.count) of \(p.rows.count)?").font(.serif(26))
            Text(trash ? "Untick anything you want to keep. Trash can be emptied later from your mail account; you can also undo for 10 seconds." : "Untick anything you want to keep. Archived mail leaves the inbox but isn't deleted; you can also undo for 10 seconds.")
                .font(.ui(15)).foregroundStyle(Palette.text2)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(p.rows) { r in
                        let id = r.message.threadId
                        Toggle(isOn: Binding(get: { !off.contains(id) }, set: { on in if on { off.remove(id) } else { off.insert(id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(r.message.fromName).font(.ui(15, .semibold)).lineLimit(1); Spacer(); Text(r.message.date.relativeShort).font(.ui(12.5)).foregroundStyle(Palette.text3) }
                                Text(r.message.subject).font(.ui(14)).foregroundStyle(Palette.text2).lineLimit(1)
                            }
                        }.toggleStyle(.checkbox).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }
            if preset == nil {
                Toggle("Offer this again when new mail like this arrives", isOn: $remember).toggleStyle(.checkbox).font(.ui(14.5))
                    .help("Saved in Settings → Mail. It never runs by itself: you'll be asked each time.")
            }
            HStack {
                Button("Back") { step = .plan }.buttonStyle(QuietButtonStyle())
                Button(off.isEmpty ? "Untick all" : "Tick all") { off = off.isEmpty ? Set(p.rows.map(\.message.threadId)) : [] }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button(trash ? "Move \(chosen.count) to Trash" : "Archive \(chosen.count)") {
                    model.applyCleanup(chosen, action: p.query.action, saveRule: remember ? p.query : nil); dismiss()
                }
                .buttonStyle(PrimaryButtonStyle()).disabled(chosen.isEmpty)
            }
        }
    }
}

/// "12 emails match your saved cleanups. Review" at the top of the inbox. Never acts by itself.
struct PendingCleanupBar: View {
    @Environment(AppModel.self) private var model
    let plans: [CleanupPlan]
    var body: some View {
        if let first = plans.first {
            let n = plans.reduce(0) { $0 + $1.rows.count }
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(Palette.accentText)
                Text(n == 1 ? "1 email matches a saved cleanup." : "\(n) emails match your saved cleanups.").font(.ui(14)).foregroundStyle(Palette.text2).lineLimit(1)
                Spacer(minLength: 6)
                Button("Review") { model.cleanupPreset = first; model.showCleanup = true }.buttonStyle(QuietButtonStyle(compact: true))
            }
        }
    }
}
