import SwiftUI
import AppKit
import EverydayCore

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    enum Step: Int, CaseIterable { case welcome, you, ai, mail, topics, swipe, done }
    @Local private var step: Step = .welcome
    @Local private var picked: Set<NewsCategory> = [.technology, .ai, .world]
    @Local private var deck: [Article] = []
    @Local private var loadingDeck = false
    @Local private var name = NSFullUserName().components(separatedBy: " ").first ?? ""
    @Local private var city = Prefs.shared.string(Prefs.Key.city, default: "Sydney")
    @Local private var provider: ProviderID = .gemini
    @Local private var key = ""
    @Local private var testing = false
    @Local private var testResult: (ok: Bool, text: String)? = nil
    @Local private var pairCode = ""
    @Local private var pairing = false
    @Local private var pairError: String?

    var body: some View {
        ZStack {
            Palette.window.ignoresSafeArea()
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    ForEach(Step.allCases, id: \.self) { s in Capsule().fill(s.rawValue <= step.rawValue ? Palette.accent : Palette.control).frame(width: 28, height: 3) }
                }.padding(.top, 44).accessibilityHidden(true)
                Spacer(minLength: 20)
                content.frame(maxWidth: step == .swipe ? 760 : 560).transition(.opacity)
                Spacer(minLength: 20)
                footer.padding(.bottom, 36)
            }.padding(.horizontal, 60)
        }.animation(.easeOut(duration: 0.2), value: step)
    }

    @ViewBuilder private var content: some View {
        switch step {
        case .welcome:
            VStack(spacing: 16) {
                HStack(spacing: 0) { Text("everyday").font(.serif(54, .medium)); Text(".").font(.serif(54, .medium)).foregroundStyle(Palette.accent) }
                Text("Mail, news and tasks in one calm place.").font(.serif(22)).foregroundStyle(Palette.text2)
                VStack(alignment: .leading, spacing: 10) {
                    promise("Your data stays on this Mac.", "No account, no servers, no analytics. Mail, news and preferences live in a local database.")
                    promise("You bring the AI.", "Your own key, stored in the macOS Keychain. You can read every request sent.")
                    promise("Nothing happens without you.", "Sending, archiving and deleting always wait for your approval.")
                }.padding(.top, 14)
                // Quick setup from a phone or PC that already has everyday.: accounts, keys and settings arrive over Wi‑Fi.
                VStack(alignment: .leading, spacing: 8) {
                    Text("Already use everyday. on another device?").font(.ui(15, .medium))
                    Text("On it, open Settings → Sync → Show pairing code, then paste the code here.").font(.ui(13.5)).foregroundStyle(Palette.text3)
                    HStack {
                        TextField("everyday-sync:1:…", text: $pairCode).textFieldStyle(.roundedBorder)
                        Button(pairing ? "Waiting for it…" : "Set up from it") {
                            do { try model.sync.join(pairCode); pairing = true; pairError = nil } catch { pairError = error.localizedDescription }
                        }.buttonStyle(QuietButtonStyle()).disabled(pairCode.isEmpty || pairing)
                    }
                    if let e = pairError { Text(e).font(.ui(13)).foregroundStyle(Palette.alertFG) }
                }.padding(14).background(RoundedRectangle(cornerRadius: 10).fill(Palette.raised)).padding(.top, 18)
            }
        case .you:
            VStack(alignment: .leading, spacing: 14) {
                Text("A little about you").font(.serif(32, .regular))
                Text("Used for greetings, drafts in your voice, and local weather.").font(.ui(16)).foregroundStyle(Palette.text2)
                field("First name", text: $name)
                field("City for weather", text: $city)
            }
        case .ai:
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose your AI").font(.serif(32, .regular))
                Text("Used to sort mail, summarize and write your briefing. You can change this any time. Skipping is fine: everything else still works.").font(.ui(16)).foregroundStyle(Palette.text2)
                HStack(spacing: 6) { ForEach([ProviderID.gemini, .anthropic, .openai, .local, .apple]) { p in Button(p.title) { provider = p; key = ""; testResult = nil }.buttonStyle(QuietButtonStyle(compact: true, selected: provider == p)) } }
                if provider.needsKey {
                    SecureField("\(provider.title) API key", text: $key).textFieldStyle(.plain).font(.ui(16)).padding(.horizontal, 12).frame(height: 38).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
                    HStack {
                        Button(testing ? "Testing…" : "Save and test") { Task { await saveAndTest() } }.buttonStyle(QuietButtonStyle()).disabled(key.trimmingCharacters(in: .whitespaces).isEmpty || testing)
                        if let r = testResult { Text(r.text).font(.ui(14.5)).foregroundStyle(r.ok ? Palette.good : Palette.alertFG).lineLimit(2) }
                    }
                    Text(provider == .gemini ? "Get a free key at aistudio.google.com/apikey." : provider == .anthropic ? "Get a key at console.anthropic.com." : "Get a key at platform.openai.com/api-keys.").font(.ui(14)).foregroundStyle(Palette.text3)
                } else if provider == .local {
                    Text("Uses an OpenAI-compatible server such as Ollama at \(model.ai.localEndpoint).").font(.ui(15)).foregroundStyle(Palette.text2)
                } else {
                    Text(AppleOnDevice.isAvailable ? "Apple Intelligence is available on this Mac. It runs entirely on device." : "Apple Intelligence is not available on this Mac.").font(.ui(15)).foregroundStyle(Palette.text2)
                }
            }
        case .mail:
            VStack(alignment: .leading, spacing: 14) {
                Text("Connect your mail").font(.serif(32, .regular))
                if model.mail.isConnected {
                    Text("Connected as \(model.mail.accountEmail ?? "").").font(.ui(18)).foregroundStyle(Palette.good)
                } else {
                    Text("Use an app password, which takes about a minute. You can skip this and connect later in Settings.").font(.ui(16)).foregroundStyle(Palette.text2)
                    MailSetupView(compact: true) { }
                }
            }
        case .topics:
            VStack(alignment: .leading, spacing: 14) {
                Text("What do you want to read?").font(.serif(32, .regular))
                Text("Pick a few. Next you'll swipe through real stories to fine-tune.").font(.ui(16)).foregroundStyle(Palette.text2)
                CategoryPicker(selected: $picked)
            }
        case .swipe:
            if loadingDeck { VStack(spacing: 12) { ProgressView(); Text("Gathering real stories from your sources…").font(.ui(16)).foregroundStyle(Palette.text2) } }
            else if deck.isEmpty { EmptyState(title: "No stories yet", message: "The news sources did not respond. You can retrain any time in Settings → Interests.") }
            else { SwipeDeck(cards: deck) { step = .done } }
        case .done:
            VStack(spacing: 14) {
                Text("You're set.").font(.serif(42, .regular))
                Text("Your briefing, inbox and news are ready. Everything is stored on this Mac.").font(.ui(18)).foregroundStyle(Palette.text2).multilineTextAlignment(.center)
            }
        }
    }

    private var footer: some View {
        HStack {
            if step != .welcome && step != .done { Button("Back") { back() }.buttonStyle(QuietButtonStyle()) }
            Spacer()
            switch step {
            case .welcome: Button("Begin") { step = .you }.buttonStyle(PrimaryButtonStyle())
            case .you: Button("Continue") { model.prefs.set(name, "userName"); model.prefs.set(city, Prefs.Key.city); step = .ai }.buttonStyle(PrimaryButtonStyle()).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            case .ai: Button(model.ai.isConfigured ? "Continue" : "Skip for now") { step = .mail }.buttonStyle(PrimaryButtonStyle())
            case .mail: Button(model.mail.isConnected ? "Continue" : "Skip for now") { step = .topics }.buttonStyle(PrimaryButtonStyle())
            case .topics: Button("Continue") { startSwipe() }.buttonStyle(PrimaryButtonStyle()).disabled(picked.isEmpty)
            case .swipe: Button("Skip swiping") { step = .done }.buttonStyle(QuietButtonStyle())
            case .done: Button("Open everyday.") { finish() }.buttonStyle(PrimaryButtonStyle())
            }
        }.frame(maxWidth: 560)
    }

    private func back() { step = Step(rawValue: max(0, step.rawValue - 1)) ?? .welcome }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.ui(14)).foregroundStyle(Palette.text3)
            TextField("", text: text).accessibilityLabel(title).textFieldStyle(.plain).font(.ui(17)).padding(.horizontal, 12).frame(height: 38).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
        }
    }

    private func promise(_ t: String, _ d: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(t).font(.ui(17, .semibold)); Text(d).font(.ui(15)).foregroundStyle(Palette.text2) }
    }

    private func saveAndTest() async {
        testing = true; defer { testing = false }
        model.ai.providerID = provider
        do { try model.ai.setAPIKey(key, for: provider); _ = try await model.ai.testConnection(); testResult = (true, "Connected.") }
        catch { testResult = (false, error.localizedDescription) }
    }

    private func startSwipe() {
        model.prefs.set(picked.map(\.rawValue), Prefs.Key.categories)
        model.interests.seed(categories: Array(picked))
        step = .swipe; loadingDeck = true
        Task {
            _ = await model.news.refresh(onlyCategories: Array(picked))
            deck = model.news.swipeDeck(categories: Array(picked), count: 20)
            loadingDeck = false
        }
    }

    private func finish() {
        model.prefs.set(true, Prefs.Key.onboarded)
        model.showOnboarding = false
        model.reloadLocal()
        Task { await model.refreshEverything() }
    }
}
