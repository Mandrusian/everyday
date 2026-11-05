import SwiftUI
import AppKit
import EverydayCore

@main
struct EverydayApp: App {
    @Local private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("everyday.") {
            RootView()
                .environment(model)
                .preferredColorScheme(scheme)
                .frame(minWidth: 1120, minHeight: 700)
                .task {
                    SpeechService.shared.ai = model.ai
                    model.start(); model.requestNotificationPermission()
                    if let dir = ProcessInfo.processInfo.environment["EVERYDAY_SNAPSHOT_DIR"] { await Snapshotter.run(model: model, dir: dir) }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task") { model.section = .tasks; NotificationCenter.default.post(name: .newTask, object: nil) }.keyboardShortcut("n")
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.section = .settings }.keyboardShortcut(",")
            }
            CommandMenu("Go") {
                ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { i, s in
                    Button(s.title) { model.section = s }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")))
                }
                Divider()
                Button("Ask everyday.") { model.showAssistant.toggle() }.keyboardShortcut("k")
                Button("Refresh Everything") { Task { await model.refreshEverything() } }.keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarContent().environment(model)
        } label: {
            let n = model.urgentCount
            Label(n > 0 ? "\(n)" : "everyday.", systemImage: "sun.max")
        }
        .menuBarExtraStyle(.window)
    }

    private var scheme: ColorScheme? {
        switch model.appearance { case "light": .light; case "system": nil; default: .dark }
    }
}

extension Notification.Name { static let newTask = Notification.Name("everyday.newTask") }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

extension AppModel {
    /// Priority mail needing action plus tasks due today, for the menu bar badge.
    var urgentCount: Int {
        let mailCount = rows.filter { ($0.triage?.priority ?? 0) >= 70 && $0.message.isUnread }.count
        let cal = Calendar.current
        let dueToday = openTasks.filter { $0.due.map { cal.isDateInToday($0) || $0 < Date() } ?? false }.count
        return mailCount + dueToday
    }
}

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("everyday.").font(.ui(16, .semibold))
            let top = model.rows.filter { ($0.triage?.priority ?? 0) >= 60 }.prefix(3)
            if !top.isEmpty {
                SectionLabel("Needs attention")
                ForEach(Array(top)) { r in
                    Button { open(.inbox, thread: r.message.threadId) } label: {
                        VStack(alignment: .leading, spacing: 0) { Text(r.message.fromName).font(.ui(14, .semibold)); Text(r.triage?.summary ?? r.message.subject).font(.ui(13)).foregroundStyle(.secondary).lineLimit(1) }
                    }.buttonStyle(.plain)
                }
            }
            let due = model.openTasks.filter { $0.due.map { Calendar.current.isDateInToday($0) || $0 < Date() } ?? false }.prefix(4)
            if !due.isEmpty {
                SectionLabel("Due today")
                ForEach(Array(due)) { t in Text("• \(t.title)").font(.ui(14)) }
            }
            if top.isEmpty && due.isEmpty { Text("Nothing needs you right now.").font(.ui(14)).foregroundStyle(.secondary) }
            Divider()
            Button("Open everyday.") { open(.today, thread: nil) }
            Button("Quit") { NSApp.terminate(nil) }
        }.padding(14).frame(width: 300)
    }
    private func open(_ s: AppSection, thread: String?) {
        model.section = s; model.selectedThread = thread
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}


/// Developer aid: `EVERYDAY_SNAPSHOT_DIR=/path open everyday.app` writes a PNG of each screen, then quits.
@MainActor enum Snapshotter {
    static func run(model: AppModel, dir: String) async {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: 9_000_000_000)
        var axReport = ""
        /// Walks the live accessibility tree (what VoiceOver reads) and records controls that have no name.
        func audit(_ name: String, _ root: Any) {
            let interactive: Set<String> = ["AXButton", "AXCheckBox", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXSlider", "AXRadioButton", "AXSwitch", "AXSecureTextField", "AXTextArea"]
            var visited = 0, controls = 0, bad: [String] = []
            func walk(_ e: Any, _ depth: Int) {
                guard depth < 40, visited < 6000 else { return }
                visited += 1
                guard let obj = e as? any NSAccessibilityProtocol else { return }
                let role = obj.accessibilityRole()?.rawValue ?? ""
                if interactive.contains(role) {
                    controls += 1
                    var named = false
                    if let l = obj.accessibilityLabel(), !l.trimmingCharacters(in: .whitespaces).isEmpty { named = true }
                    if let t = obj.accessibilityTitle(), !t.trimmingCharacters(in: .whitespaces).isEmpty { named = true }
                    if let h = obj.accessibilityHelp(), !h.trimmingCharacters(in: .whitespaces).isEmpty { named = true }
                    if let v = obj.accessibilityValue() as? String, !v.trimmingCharacters(in: .whitespaces).isEmpty { named = true }
                    if !named { bad.append("\(role) at \(NSStringFromRect(obj.accessibilityFrame()))") }
                }
                for c in obj.accessibilityChildren() ?? [] { walk(c, depth + 1) }
            }
            walk(root, 0)
            axReport += "\(name): \(controls) controls, \(bad.count) without a name\n" + bad.prefix(12).map { "   - \($0)\n" }.joined()
        }
        func shot(_ name: String) async {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if let w = NSApp.windows.filter({ $0.contentView != nil && $0.isVisible }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }), ProcessInfo.processInfo.environment["EVERYDAY_AX_AUDIT"] != nil { audit(name, w) }
            guard let view = NSApp.windows.filter({ $0.contentView != nil && $0.isVisible }).max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height })?.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
        }
        if model.showOnboarding { await shot("onboarding-welcome"); model.showOnboarding = false }
        for s in AppSection.allCases { model.section = s; await shot(s.rawValue) }
        if let b = MailBundler.items(from: model.rows).compactMap({ i -> MailBundle? in if case .bundle(let b) = i { return b }; return nil }).first {
            model.section = .inbox; model.selectedThread = nil; model.selectedBundleID = b.id
            await shot("inbox-bundle")
        }
        model.section = .settings
        for p in SettingsPane.allCases { model.settingsPane = p; await shot("settings-\(p.rawValue.replacingOccurrences(of: " ", with: "-"))") }
        if !axReport.isEmpty { try? axReport.write(toFile: "\(dir)/ax-audit.txt", atomically: true, encoding: .utf8) }
        NSApp.terminate(nil)
    }
}
