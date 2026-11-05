import SwiftUI
import EverydayCore

/// "Archive these 23 newsletters?" as a list you can read and edit first. Nothing happens until the button is pressed.
struct BulkArchiveSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let rows: [MailRow]
    @Local private var off: Set<String> = []

    private var chosen: [String] { rows.map(\.message.threadId).filter { !off.contains($0) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Archive \(chosen.count) of \(rows.count) newsletters and promotions?").font(.serif(26))
            Text("Untick anything you want to keep. Archiving moves mail out of your inbox; it is not deleted, and you can undo it right after.").font(.ui(15)).foregroundStyle(Palette.text2)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(rows) { r in
                        let id = r.message.threadId
                        Toggle(isOn: Binding(get: { !off.contains(id) }, set: { on in if on { off.remove(id) } else { off.insert(id) } })) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(r.message.fromName).font(.ui(15, .semibold)).lineLimit(1)
                                Text(r.message.subject).font(.ui(14)).foregroundStyle(Palette.text2).lineLimit(1)
                            }
                        }.toggleStyle(.checkbox).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Hairline() }
                    }
                }
            }
            HStack {
                Button("Cancel") { dismiss() }.buttonStyle(QuietButtonStyle())
                Button(off.isEmpty ? "Untick all" : "Tick all") { off = off.isEmpty ? Set(rows.map(\.message.threadId)) : [] }.buttonStyle(QuietButtonStyle())
                Spacer()
                Button("Archive \(chosen.count)") { model.archiveThreads(chosen); dismiss() }.buttonStyle(PrimaryButtonStyle()).disabled(chosen.isEmpty)
            }
        }.padding(24).frame(width: 560, height: 560).background(Palette.window)
    }
}
