import SwiftUI
import EverydayCore

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SidebarView()
                ZStack {
                    switch model.section {
                    case .today: TodayView().id(AppSection.today)
                    case .inbox: InboxView().id(AppSection.inbox)
                    case .news: NewsView().id(AppSection.news)
                    case .tasks: TasksView().id(AppSection.tasks)
                    case .saved: SavedView().id(AppSection.saved)
                    case .settings: SettingsView().id(AppSection.settings)
                    }
                }
                .transition(.opacity.combined(with: .offset(y: 6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .paper(Palette.window)
                if model.showAssistant {
                    Hairline(vertical: true)
                    AssistantPanel().frame(width: 380).transition(.move(edge: .trailing))
                }
            }
            .animation(.easeOut(duration: 0.18), value: model.showAssistant)
            .animation(Motion.gentle, value: model.section)

            if let b = model.banner {
                VStack { Spacer(); BannerView(banner: b).padding(.bottom, 22) }.transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.showOnboarding {
                OnboardingView().transition(.opacity)
            }
        }
        .paper(Palette.window)
        .animation(Motion.spring, value: model.banner)
        .animation(.easeOut(duration: 0.25), value: model.showOnboarding)
        .ignoresSafeArea()
    }
}

struct BannerView: View {
    @Environment(AppModel.self) private var model
    let banner: Banner
    var body: some View {
        HStack(spacing: 14) {
            Text(banner.text).font(.ui(14.5)).foregroundStyle(banner.isError ? Palette.alertFG : Palette.text)
            if let undo = banner.undo { Button("Undo") { undo(); model.banner = nil }.buttonStyle(.plain).font(.ui(14.5, .semibold)).foregroundStyle(Palette.accentText) }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(banner.isError ? Palette.alertBG : Palette.control))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
        .frame(maxWidth: 620)
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    @Namespace private var selection

    private func count(_ s: AppSection) -> Int {
        switch s {
        case .inbox: return model.rows.filter { $0.message.isUnread }.count
        case .tasks: return model.openTasks.count
        default: return 0
        }
    }

    private var slim: Bool { model.sidebarCollapsed }

    var body: some View {
        VStack(alignment: slim ? .center : .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text(slim ? "e" : "everyday").font(.serif(24, .semibold)).foregroundStyle(Palette.text)
                Text(".").font(.serif(24, .semibold)).foregroundStyle(Palette.accent)
                if !slim { Spacer(); collapseButton }
            }.padding(.horizontal, slim ? 0 : 10).padding(.top, 40).padding(.bottom, slim ? 8 : 16)
            if slim { collapseButton.padding(.bottom, 8) }

            ForEach(AppSection.allCases.filter { $0 != .settings }) { s in
                SidebarRow(title: s.title, symbol: s.symbol, count: count(s), selected: model.section == s, ns: selection, slim: slim) { model.section = s }
            }

            if slim {
                Hairline().frame(width: 28).padding(.vertical, 12)
                focus("Needs reply", .needsReply, Palette.accent, model.rows.filter { $0.triage?.needsReply == true }.count)
                focus("Deadlines", .deadlines, Palette.alertFG, model.rows.filter { $0.triage?.deadline != nil }.count)
                focus("Newsletters", .newsletters, Palette.text3, model.rows.filter { $0.triage?.category == .newsletter }.count)
            } else {
                Text("FOCUS").font(.ui(12, .semibold)).tracking(1.4).foregroundStyle(Palette.text3).padding(.horizontal, 10).padding(.top, 22).padding(.bottom, 4)
                focus("Needs reply", .needsReply, Palette.accent, model.rows.filter { $0.triage?.needsReply == true }.count)
                focus("Deadlines", .deadlines, Palette.alertFG, model.rows.filter { $0.triage?.deadline != nil }.count)
                focus("Newsletters", .newsletters, Palette.text3, model.rows.filter { $0.triage?.category == .newsletter }.count)
            }

            Spacer()
            SidebarRow(title: "Settings", symbol: AppSection.settings.symbol, count: 0, selected: model.section == .settings, ns: selection, slim: slim) { model.section = .settings }
            Button { model.showAssistant.toggle() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left").font(.system(size: 14))
                    if !slim {
                        Text("Ask everyday.").font(.ui(15))
                        Spacer()
                        Text("⌘K").font(.ui(13)).foregroundStyle(Palette.text3)
                    }
                }.foregroundStyle(Palette.text).padding(.horizontal, slim ? 0 : 12).frame(width: slim ? 38 : nil, height: 38)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised)).overlay(RoundedRectangle(cornerRadius: 8).stroke(Palette.line))
            }.buttonStyle(.plain).padding(.top, 8).help("Ask everyday. (⌘K)")

            Button { if model.mail.isConnected { Task { await model.syncMail() } } else { model.settingsPane = .accounts; model.section = .settings } } label: {
            HStack(spacing: 10) {
                Circle().fill(model.mailError != nil ? Palette.alertBG : Palette.control).frame(width: 28, height: 28).overlay(Text(String(model.userName.prefix(1)).uppercased()).font(.ui(14)).foregroundStyle(Palette.text))
                if !slim { VStack(alignment: .leading, spacing: 0) {
                    Text(model.mail.accountEmails.count > 1 ? "\(model.mail.accountEmails.count) mail accounts" : (model.mail.accountEmail ?? "No mail account")).font(.ui(13.5)).foregroundStyle(Palette.text).lineLimit(1)
                    Text(statusLine).font(.ui(12.5)).foregroundStyle(model.mailError != nil ? Palette.alertFG : Palette.text3).lineLimit(1)
                } }
            }.contentShape(Rectangle())
            }.buttonStyle(.plain).help(model.mailError ?? (slim ? statusLine : "Sync now")).padding(.horizontal, slim ? 0 : 8).padding(.top, 12)
        }
        .padding(.horizontal, slim ? 8 : 10).padding(.bottom, 14)
        .frame(width: slim ? 64 : 232).frame(maxHeight: .infinity)
        .clipped()
        .animation(Motion.snappy, value: slim)
        .paper(Palette.sidebar)
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
    }

    private var statusLine: String {
        if model.syncingMail || model.triaging { return model.mailProgress.isEmpty ? "Syncing…" : model.mailProgress }
        if model.mailError != nil { return "Sync failed. Click to retry" }
        if let d = model.mail.lastSync { return "Synced \(d.relativeShort), on device" }
        return model.mail.isConnected ? "Not synced yet" : "Connect mail in Settings"
    }

    /// Shrinks the sidebar to icons (⌃⌘S, the standard Mac shortcut).
    private var collapseButton: some View {
        Button { model.sidebarCollapsed.toggle() } label: {
            Image(systemName: "sidebar.left").font(.system(size: 13)).foregroundStyle(Palette.text3).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).keyboardShortcut("s", modifiers: [.control, .command])
        .help(slim ? "Expand the sidebar (⌃⌘S)" : "Collapse the sidebar to icons (⌃⌘S)")
        .accessibilityLabel(slim ? "Expand sidebar" : "Collapse sidebar")
    }

    @ViewBuilder private func focus(_ title: String, _ f: InboxFilter, _ color: Color, _ n: Int) -> some View {
        if slim {
            Button { model.inboxFilter = f; model.section = .inbox } label: {
                ZStack(alignment: .topTrailing) {
                    Circle().fill(color).frame(width: 9, height: 9).frame(width: 38, height: 30)
                    if n > 0 { Text("\(n)").font(.ui(10.5, .semibold)).foregroundStyle(Palette.text3).offset(x: -2, y: 1) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(title): \(n)").accessibilityLabel("\(title), \(n)")
        } else {
        Button { model.inboxFilter = f; model.section = .inbox } label: {
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 7, height: 7).padding(.horizontal, 5)
                Text(title).font(.ui(15)).foregroundStyle(Palette.text2)
                Spacer()
                Text("\(n)").font(.ui(13)).foregroundStyle(Palette.text3)
            }.frame(height: 30).padding(.horizontal, 6).contentShape(Rectangle())
        }.buttonStyle(.plain)
        }
    }
}

struct SidebarRow: View {
    let title: String, symbol: String, count: Int, selected: Bool, ns: Namespace.ID
    var slim = false
    let action: () -> Void
    @Local private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 20)
                    .overlay(alignment: .topTrailing) { if slim && count > 0 { Circle().fill(Palette.accent).frame(width: 6, height: 6).offset(x: 4, y: -2) } }
                if !slim {
                    Text(title).font(.ui(16, selected ? .semibold : .regular))
                    Spacer()
                    if count > 0 { Text("\(count)").font(.ui(13)).foregroundStyle(Palette.text3) }
                }
            }
            .foregroundStyle(selected ? Palette.text : Palette.text2)
            .padding(.horizontal, slim ? 0 : 10).frame(width: slim ? 42 : nil, height: 34)
            .background { ZStack { if hover && !selected { RoundedRectangle(cornerRadius: 7).fill(Palette.raised) }; if selected { RoundedRectangle(cornerRadius: 7).fill(Palette.control).matchedGeometryEffect(id: "sel", in: ns) } } }
            .animation(Motion.snappy, value: selected)
            .contentShape(Rectangle())
        }.buttonStyle(.plain).onHover { hover = $0 }
        .help(slim ? (count > 0 ? "\(title) (\(count))" : title) : "")
        .accessibilityLabel(title)
    }
}
