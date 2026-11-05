import Foundation

/// Non-secret preferences. Secrets never go here (see Keychain).
public final class Prefs: @unchecked Sendable {
    public static let shared = Prefs()
    private let d: UserDefaults
    private let suite: String
    /// Separate suites keep self-checks from touching real app settings.
    public init(suite: String = ProcessInfo.processInfo.environment["EVERYDAY_DEV"] == "1" ? "everyday.app.dev" : "everyday.app") { self.suite = suite; d = UserDefaults(suiteName: suite) ?? .standard }

    public enum Key {
        public static let provider = "ai.provider"
        public static let triageModel = "ai.model.triage"
        public static let summaryModel = "ai.model.summary"
        public static let chatModel = "ai.model.chat"
        public static let localEndpoint = "ai.local.endpoint"
        public static let budgetUSD = "ai.budget.usd"
        public static let sendFullBodies = "ai.sendFullBodies"
        public static let onboarded = "onboarded"
        public static let categories = "news.categories"
        public static let city = "weather.city"
        public static let freshnessHours = "news.freshnessHours"
        public static let googleClientID = "google.clientID"
        public static let googleEmail = "google.email"
        public static let syncDays = "mail.syncDays"
        public static let briefingHour = "briefing.hour"
        public static let outsideBubble = "news.outsideBubble"
        public static let notifications = "notifications.enabled"
        public static let remindersSync = "tasks.remindersSync"
        public static let appearance = "appearance"
        public static let mirrorGmailLabels = "mail.mirrorLabels"
        public static let briefingSections = "briefing.sections"          // [String]: mail, calendar, weather, news, tasks
        public static let briefingNewsCount = "briefing.newsCount"
        public static let briefingInstructions = "briefing.instructions"  // free text the reader writes
        public static let widgetStyle = "widgets.style"                  // "flat" or "glass"
        public static let countdowns = "widgets.countdowns"              // JSON [WidgetSnapshot.Countdown]
        public static let customWidgets = "widgets.customs"              // JSON [WidgetSnapshot.Custom]
        public static let quoteTopic = "widgets.quoteTopic"              // topic for the quote-of-the-day widget
        public static let followedTopics = "news.followedTopics"         // the reader's own topics, by name
        public static let briefingPrompt = "briefing.prompt"              // Advanced: replaces the default writing instructions
        public static let mutedTopics = "news.mutedTopics"                // [String] keywords hidden everywhere
        public static let briefingAutoRewrite = "briefing.autoRewrite"
        public static let briefingNotify = "briefing.notify"
        public static let autoUpdateCheck = "updates.auto"
        public static let lastUpdateCheck = "updates.last"
        public static let briefingLastNotified = "briefing.lastNotified"
    }

    public func string(_ k: String, default def: String = "") -> String { d.string(forKey: k) ?? def }
    public func set(_ v: String, _ k: String) { d.set(v, forKey: k) }
    public func bool(_ k: String, default def: Bool = false) -> Bool { d.object(forKey: k) == nil ? def : d.bool(forKey: k) }
    public func set(_ v: Bool, _ k: String) { d.set(v, forKey: k) }
    public func double(_ k: String, default def: Double) -> Double { d.object(forKey: k) == nil ? def : d.double(forKey: k) }
    public func set(_ v: Double, _ k: String) { d.set(v, forKey: k) }
    public func strings(_ k: String) -> [String] { d.stringArray(forKey: k) ?? [] }
    public func set(_ v: [String], _ k: String) { d.set(v, forKey: k) }
    public func remove(_ k: String) { d.removeObject(forKey: k) }
    public func resetAll() { d.removePersistentDomain(forName: suite) }
}
