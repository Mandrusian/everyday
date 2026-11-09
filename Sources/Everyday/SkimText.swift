import SwiftUI
import AppKit
import EverydayCore

extension SkimMarkup.Kind {
    var color: Color {
        switch self {
        case .urgent: return Palette.alertFG
        case .action: return Palette.clayText
        case .date: return Palette.amber
        case .person: return Palette.infoFG
        case .money: return Palette.teal
        case .number: return Palette.good
        case .place: return Palette.lavender
        }
    }
    var title: String {
        switch self {
        case .urgent: "Urgent or deadline"; case .action: "Things to do"; case .date: "Dates and times"; case .person: "People and organisations"
        case .money: "Money"; case .number: "Numbers"; case .place: "Places"
        }
    }
}

/// Text for skim reading: key phrases get a colour, a soft tint behind them and a heavier weight.
/// With highlights off the tags are stripped and the text is plain. Sans or serif follows the reader's setting.
/// With `smooth`, text that grows (a stream from the model) is revealed at an even pace instead of in bursts.
struct SkimBody: View {
    @Environment(AppModel.self) private var model
    let text: String
    var size: CGFloat = 17
    var muted = false
    var smooth = false

    @Local private var shown = -1          // characters revealed; -1 until first layout
    @Local private var catching = false

    var body: some View {
        let font: Font = model.skimSans ? .system(size: size - 1.5) : .serif(size)
        let visible = smooth && shown >= 0 && shown < text.count ? String(text.prefix(shown)) : text
        let parts = Briefing.sections(visible)
        Group {
            if parts.contains(where: { $0.heading != nil }) {
                // A briefing written in sections: small headings, then each section's text.
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                        VStack(alignment: .leading, spacing: 4) {
                            if let h = p.heading { Text(Markdown.plain(SkimMarkup.strip(h))).font(.ui(12.5, .semibold)).tracking(0.4).foregroundStyle(Palette.accentText) }
                            paragraph(p.body)
                        }
                    }
                }
            } else { paragraph(visible) }
        }
        .font(font).lineSpacing(model.skimSans ? 5 : 6).foregroundStyle(muted ? Palette.text2 : Palette.text).textSelection(.enabled)
        .onAppear { if shown < 0 { shown = text.count }; latest = text }
        .onChange(of: text) { _, new in
            latest = new
            guard smooth, !Motion.reduce else { shown = new.count; return }
            if shown < 0 { shown = 0 }
            if shown > new.count { shown = new.count }
            guard !catching else { return }
            catching = true
            Task {
                // Even pace: a few characters per frame, faster when far behind so it never lags the model by much.
                while let target = Optional(latest.count), shown < target {
                    shown = min(target, shown + max(1, (target - shown) / 14))
                    try? await Task.sleep(nanoseconds: 16_000_000)
                }
                catching = false
            }
        }
        .onChange(of: smooth) { _, on in if !on { shown = text.count } }
    }

    @Local private var latestBox = ""
    private var latest: String { get { latestBox } nonmutating set { latestBox = newValue } }

    /// Paragraphs and lists from light markdown; bullets hang so wrapped lines line up with the text.
    @ViewBuilder private func paragraph(_ t: String) -> some View {
        let blocks = Markdown.blocks(t)
        if blocks.count <= 1, case .paragraph(let p)? = blocks.first { line(p) }
        else {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                    switch b {
                    case .paragraph(let p): line(p)
                    case .bullet(let p): HStack(alignment: .firstTextBaseline, spacing: 8) { Text("•").foregroundStyle(Palette.accentText); line(p) }
                    case .numbered(let n, let p): HStack(alignment: .firstTextBaseline, spacing: 8) { Text(n).foregroundStyle(Palette.text3).monospacedDigit(); line(p) }
                    }
                }
            }
        }
    }

    private func line(_ t: String) -> some View { Text(attributed(t)).fixedSize(horizontal: false, vertical: true) }

    /// Skim tags become coloured phrases (when highlights are on); **bold**, *italics*, `code` and [links](url) are rendered.
    /// Bold may span tags, so it is tracked across segments rather than parsed per segment.
    private func attributed(_ t: String) -> AttributedString {
        var out = AttributedString()
        var bold = false
        for seg in SkimMarkup.segments(t) {
            let pieces = seg.text.components(separatedBy: "**")
            for (i, piece) in pieces.enumerated() {
                if i > 0 { bold.toggle() }
                guard !piece.isEmpty else { continue }
                var a = (try? AttributedString(markdown: piece, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(piece)
                if bold { a.inlinePresentationIntent = (a.inlinePresentationIntent ?? []).union(.stronglyEmphasized) }
                for run in a.runs where run.link != nil { a[run.range].foregroundColor = Palette.accentText; a[run.range].underlineStyle = .single }
                if model.skim, let k = seg.kind {
                    a.foregroundColor = k.color
                    a.backgroundColor = k.color.opacity(0.16)
                    a.inlinePresentationIntent = (a.inlinePresentationIntent ?? []).union(.stronglyEmphasized)
                }
                out += a
            }
        }
        return out
    }
}

/// Colour key shown in Settings and from the briefing header.
struct SkimLegend: View {
    var body: some View {
        FlowLayout(spacing: 14) {
            ForEach(SkimMarkup.Kind.allCases, id: \.rawValue) { k in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 3).fill(k.color.opacity(0.35)).overlay(RoundedRectangle(cornerRadius: 3).stroke(k.color)).frame(width: 14, height: 14)
                    Text(k.title).font(.ui(13)).foregroundStyle(Palette.text2)
                }
            }
        }
    }
}
