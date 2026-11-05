import SwiftUI
import AppKit

/// Flat, warm, dark-first palette. Every colour resolves per appearance so Light mode stays coherent.
enum Palette {
    private static func dyn(_ dark: UInt32, _ light: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { app in
            let isDark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
    static let window = dyn(0x1c1b19, 0xfaf9f5)
    static let sidebar = dyn(0x171614, 0xefece3)
    static let raised = dyn(0x25231f, 0xf3efe5)
    static let control = dyn(0x2d2b27, 0xe9e4d7)
    static let selected = dyn(0x2a2723, 0xece5d3)
    static let line = dyn(0x33312c, 0xe2d9c8)
    static let softLine = dyn(0x2b2926, 0xebe4d4)
    static let text = dyn(0xece8df, 0x1f1e1d)
    static let text2 = dyn(0xa39e92, 0x5e5b52)
    static let text3 = dyn(0x8c887d, 0x6b675c)
    static let accent = dyn(0xd97757, 0xb5532f)
    static let onAccent = dyn(0x1c1b19, 0xffffff)
    static let accentText = dyn(0xe8916f, 0x9a4424)
    static let good = dyn(0xaebf8a, 0x4a5530)
    static let amber = dyn(0xe6c05f, 0x7a5a0c)
    static let warnBG = dyn(0x3b2a22, 0xf6e2d6)
    static let warnFG = dyn(0xe8a184, 0x8a3f22)
    static let alertBG = dyn(0x3e2523, 0xf3d9d4)
    static let alertFG = dyn(0xee9e96, 0x8b2e25)
    static let infoBG = dyn(0x26303a, 0xdfe6ec)
    static let infoFG = dyn(0x9dbad0, 0x33495c)
    static let quietBG = dyn(0x2b2a26, 0xe9e4d6)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
}

extension Font {
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: size, weight: weight, design: .serif) }
    static func serifItalic(_ size: CGFloat) -> Font { .system(size: size, design: .serif).italic() }
    /// Interface text: the system sans, slightly smaller than the editorial serif used for reading.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font { .system(size: (size * 0.9 * 2).rounded() / 2, weight: weight) }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text.uppercased()).font(.ui(11.5, .semibold)).tracking(1.4).foregroundStyle(Palette.accentText).lineLimit(1).fixedSize()
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.ui(compact ? 13.5 : 14.5, .semibold)).foregroundStyle(Palette.onAccent)
            .padding(.horizontal, compact ? 11 : 15).frame(height: compact ? 26 : 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(Palette.accent.opacity(c.isPressed ? 0.8 : 1)))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(c.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.12), value: c.isPressed)
    }
}

struct QuietButtonStyle: ButtonStyle {
    var compact = false
    var selected = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration c: Configuration) -> some View {
        c.label.font(.ui(compact ? 13.5 : 14.5, selected ? .semibold : .regular)).foregroundStyle(selected ? Palette.window : Palette.text)
            .padding(.horizontal, compact ? 11 : 14).frame(height: compact ? 26 : 32)
            .background(RoundedRectangle(cornerRadius: 7).fill(selected ? Palette.text : (c.isPressed ? Palette.line : Palette.control)))
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(c.isPressed ? 0.97 : 1).animation(.easeOut(duration: 0.12), value: c.isPressed)
            .animation(.easeOut(duration: 0.18), value: selected)
    }
}

struct Chip: View {
    enum Kind { case reply, deadline, important, quiet, good }
    let text: String
    let kind: Kind
    var body: some View {
        let (bg, fg): (Color, Color) = {
            switch kind {
            case .reply: return (Palette.warnBG, Palette.warnFG)
            case .deadline: return (Palette.alertBG, Palette.alertFG)
            case .important: return (Palette.infoBG, Palette.infoFG)
            case .quiet: return (Palette.quietBG, Palette.text2)
            case .good: return (Palette.quietBG, Palette.good)
            }
        }()
        Text(text).font(.ui(12)).foregroundStyle(fg).padding(.horizontal, 7).padding(.vertical, 1).background(RoundedRectangle(cornerRadius: 4).fill(bg))
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View { Rectangle().fill(Palette.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1) }
}

struct PaneHeader<Trailing: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(spacing: 12) {
            Text(title).font(.ui(18, .semibold)).foregroundStyle(Palette.text)
            if let s = subtitle { Text(s).font(.ui(15)).foregroundStyle(Palette.text2) }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 24).frame(height: 52)
        .overlay(alignment: .bottom) { Hairline() }
    }
}
extension PaneHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) { self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }) }
}

struct EmptyState: View {
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?
    var body: some View {
        VStack(spacing: 10) {
            Text(title).font(.serif(22, .medium)).foregroundStyle(Palette.text)
            Text(message).font(.ui(15)).foregroundStyle(Palette.text2).multilineTextAlignment(.center).frame(maxWidth: 360)
            if let a = action { Button(a.title, action: a.run).buttonStyle(PrimaryButtonStyle()).padding(.top, 6) }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
    }
}

extension Date {
    var relativeShort: String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(self) { f.dateFormat = "h:mm a" }
        else if cal.isDateInYesterday(self) { return "Yesterday" }
        else if let d = cal.dateComponents([.day], from: self, to: Date()).day, d < 7 { f.dateFormat = "EEE" }
        else { f.dateFormat = "d MMM" }
        return f.string(from: self)
    }
    var ageShort: String {
        let m = Int(Date().timeIntervalSince(self) / 60)
        if m < 60 { return "\(max(m, 1))m" }
        if m < 60 * 24 { return "\(m / 60)h" }
        return "\(m / 1440)d"
    }
}

/// `@State` is a compiler macro in the macOS 27 SDK and its plugin ships only with Xcode, so view-local
/// state uses this equivalent wrapper around the `State` storage type instead.
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private let box: State<Value>
    init(wrappedValue: Value) { box = State(initialValue: wrappedValue) }
    var wrappedValue: Value { get { box.wrappedValue } nonmutating set { box.wrappedValue = newValue } }
    var projectedValue: Binding<Value> { box.projectedValue }
}


/// Lays children out left to right and wraps to the next line, so buttons never overlap or run together.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { y += rowH + spacing; x = 0; rowH = 0 }
            x += s.width + spacing; rowH = max(rowH, s.height); maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; rowH = max(rowH, s.height)
        }
    }
}


// MARK: Polish helpers

/// A soft moving highlight for loading placeholders. Static when Reduce Motion is on.
struct Shimmer: ViewModifier {
    @Local private var phase: CGFloat = -1
    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { g in
                LinearGradient(colors: [.clear, Palette.text.opacity(0.07), .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: g.size.width * 0.6).offset(x: phase * g.size.width * 1.6)
            }.clipped().allowsHitTesting(false)
        ).onAppear { guard !Motion.reduce else { return }; withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 } }
    }
}
extension View { func shimmer() -> some View { modifier(Shimmer()) } }

/// Placeholder rows shown while mail or news is loading, so the screen never looks empty or frozen.
struct SkeletonRows: View {
    var count = 6
    var body: some View {
        VStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                VStack(alignment: .leading, spacing: 8) {
                    RoundedRectangle(cornerRadius: 4).fill(Palette.control).frame(width: CGFloat(120 + (i * 37) % 90), height: 12)
                    RoundedRectangle(cornerRadius: 4).fill(Palette.control).frame(height: 10)
                    RoundedRectangle(cornerRadius: 4).fill(Palette.control).frame(width: CGFloat(180 + (i * 53) % 110), height: 10)
                }.padding(.horizontal, 20).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading).overlay(alignment: .bottom) { Hairline() }
            }
        }.shimmer().accessibilityLabel("Loading").opacity(0.9)
    }
}

/// Rows ease in one after another the first time they appear (first dozen only, and not at all with Reduce Motion).
struct Entrance: ViewModifier {
    let index: Int
    @Local private var shown = false
    func body(content: Content) -> some View {
        content.opacity(shown || Motion.reduce ? 1 : 0).offset(y: shown || Motion.reduce ? 0 : 8)
            .onAppear { guard !shown else { return }; if index > 12 || Motion.reduce { shown = true; return }; withAnimation(.easeOut(duration: 0.28).delay(Double(index) * 0.035)) { shown = true } }
    }
}
extension View { func entrance(_ index: Int) -> some View { modifier(Entrance(index: index)) } }

/// A task checkbox whose ring fills and whose tick draws itself.
struct TaskCheck: View {
    let done: Bool
    @Local private var pop = false
    var body: some View {
        ZStack {
            Circle().stroke(done ? Palette.accent : Palette.text3, lineWidth: 1.7)
            Circle().fill(Palette.accent).scaleEffect(done ? 1 : 0.2).opacity(done ? 1 : 0)
            CheckShape().trim(from: 0, to: done ? 1 : 0).stroke(Palette.window, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)).padding(5.5)
        }.frame(width: 20, height: 20).scaleEffect(pop ? 1.18 : 1)
        .animation(Motion.spring, value: done)
        .onChange(of: done) { _, d in guard d, !Motion.reduce else { return }; withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) { pop = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { pop = false } } }
    }
}
struct CheckShape: Shape {
    func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.minX + r.width * 0.05, y: r.midY + r.height * 0.05)); p.addLine(to: CGPoint(x: r.minX + r.width * 0.38, y: r.maxY - r.height * 0.1)); p.addLine(to: CGPoint(x: r.maxX - r.width * 0.02, y: r.minY + r.height * 0.1)); return p }
}
