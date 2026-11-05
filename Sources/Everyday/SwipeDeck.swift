import SwiftUI
import EverydayCore

/// Card-stack curation: right = interested, left = not for me, up = especially interested.
struct SwipeDeck: View {
    @Environment(AppModel.self) private var model
    let cards: [Article]
    var onFinish: () -> Void

    @Local private var index = 0
    @Local private var drag: CGSize = .zero
    @Local private var counts = (like: 0, love: 0, skip: 0)
    @Local private var flying: CGSize? = nil
    @FocusState private var focused: Bool

    private var current: Article? { index < cards.count ? cards[index] : nil }

    var body: some View {
        VStack(spacing: 18) {
            Text("\(min(index + 1, cards.count)) of \(cards.count)").font(.ui(13, .semibold)).tracking(1.4).foregroundStyle(Palette.accentText)
            ZStack {
                ForEach(Array(cards.enumerated().filter { $0.offset > index && $0.offset <= index + 2 }.reversed()), id: \.element.id) { i, a in
                    card(a).scaleEffect(1 - CGFloat(i - index) * 0.04).offset(y: CGFloat(i - index) * 10).opacity(0.7)
                }
                if let a = current {
                    card(a)
                        .overlay(stamp)
                        .offset(flying ?? drag).rotationEffect(.degrees(Double((flying ?? drag).width) / 22))
                        .gesture(DragGesture().onChanged { drag = $0.translation }.onEnded { v in
                            let t = v.translation
                            if t.height < -110 && abs(t.width) < 160 { commit(.love) } else if t.width > 120 { commit(.like) } else if t.width < -120 { commit(.dislike) } else { withAnimation(.spring(duration: 0.3)) { drag = .zero } }
                        })
                        .id(a.id)
                }
                if current == nil {
                    VStack(spacing: 10) {
                        Text("That's enough to start.").font(.serif(24, .medium))
                        Text("You rated \(counts.like + counts.love + counts.skip) stories. Your feed will keep learning from what you read and save.").font(.ui(15.5)).foregroundStyle(Palette.text2).multilineTextAlignment(.center).frame(width: 340)
                        Button("Continue") { onFinish() }.buttonStyle(PrimaryButtonStyle()).padding(.top, 6)
                    }
                }
            }.frame(width: 440, height: 440)
            if current != nil {
                HStack(spacing: 12) {
                    action("Not for me", "xmark", Palette.alertFG, "←") { commit(.dislike) }
                    action("Love it", "star", Palette.infoFG, "↑") { commit(.love) }
                    Button { commit(.like) } label: { Label("Interested  →", systemImage: "heart").font(.ui(15, .semibold)).frame(width: 150, height: 42) }
                        .buttonStyle(.plain).foregroundStyle(Palette.onAccent).background(RoundedRectangle(cornerRadius: 8).fill(Palette.accent))
                        .accessibilityLabel("Interested")
                }
                Text("Drag the card, use the buttons, or press the arrow keys.").font(.ui(13.5)).foregroundStyle(Palette.text3)
            }
        }
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(.leftArrow) { commit(.dislike); return .handled }
        .onKeyPress(.rightArrow) { commit(.like); return .handled }
        .onKeyPress(.upArrow) { commit(.love); return .handled }
        .onAppear { focused = true }
    }

    private func action(_ title: String, _ icon: String, _ color: Color, _ key: String, run: @escaping () -> Void) -> some View {
        Button(action: run) { Label("\(title)  \(key)", systemImage: icon).font(.ui(15)).foregroundStyle(color).frame(width: 150, height: 42) }
            .buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 8).fill(Palette.control)).accessibilityLabel(title)
    }

    @ViewBuilder private var stamp: some View {
        let d = flying ?? drag
        if d.height < -40 && abs(d.width) < 100 { stampLabel("LOVE IT", Palette.infoFG) }
        else if d.width > 40 { stampLabel("INTERESTED", Palette.good) }
        else if d.width < -40 { stampLabel("NOT FOR ME", Palette.alertFG) }
    }
    private func stampLabel(_ t: String, _ c: Color) -> some View {
        Text(t).font(.ui(18, .bold)).tracking(2).foregroundStyle(c).padding(.horizontal, 12).padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(c, lineWidth: 2)).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).allowsHitTesting(false)
    }

    private func card(_ a: Article) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                if let s = a.imageURL, let u = URL(string: s) { AsyncImage(url: u) { p in if let i = p.image { i.resizable().scaledToFill() } else { Rectangle().fill(Palette.control) } } }
                else { Rectangle().fill(Palette.control) }
            }.frame(height: 150).clipped().accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) { Chip(text: a.categories.first?.title ?? "News", kind: .reply); Text(a.source).font(.ui(14)).foregroundStyle(Palette.text2) }
                Text(a.title).font(.serif(23, .medium)).lineLimit(4).foregroundStyle(Palette.text)
                if !a.summary.isEmpty { Text(a.summary).font(.ui(15.5)).foregroundStyle(Palette.text2).lineLimit(3) }
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(width: 420, height: 420).background(RoundedRectangle(cornerRadius: 12).fill(Palette.raised)).clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line))
    }

    private func commit(_ r: Reaction) {
        guard let a = current, flying == nil else { return }
        let target: CGSize = r == .love ? CGSize(width: 0, height: -700) : r == .like ? CGSize(width: 700, height: 0) : CGSize(width: -700, height: 0)
        withAnimation(.easeIn(duration: 0.22)) { flying = target }
        model.news.interests.record(a, reaction: Double(r.rawValue) * (r == .dislike ? 1 : 1))
        switch r { case .love: counts.love += 1; case .like: counts.like += 1; case .dislike: counts.skip += 1 }
        Task {
            try? await Task.sleep(nanoseconds: 230_000_000)
            index += 1; flying = nil; drag = .zero
            if index >= cards.count { model.reloadNews() }
        }
    }
}

struct CategoryPicker: View {
    @Binding var selected: Set<NewsCategory>
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
            ForEach(NewsCategory.allCases) { c in
                let on = selected.contains(c)
                Button { if on { selected.remove(c) } else { selected.insert(c) } } label: {
                    HStack { Text(c.title).font(.ui(16, on ? .semibold : .regular)); Spacer(); if on { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) } }
                        .padding(.horizontal, 14).frame(height: 46).foregroundStyle(on ? Palette.onAccent : Palette.text)
                        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Palette.accent : Palette.raised))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? Color.clear : Palette.line))
                }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }
}
