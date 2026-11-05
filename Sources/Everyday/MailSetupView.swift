import SwiftUI
import AppKit
import EverydayCore

/// "Connect your mail": pick a provider, follow three short steps, paste an app password. Used in onboarding and Settings.
struct MailSetupView: View {
    @Environment(AppModel.self) private var model
    var compact = false
    var onConnected: () -> Void = {}

    @Local private var email = ""
    @Local private var password = ""
    @Local private var presetID = "gmail"
    @Local private var imapHost = ""
    @Local private var smtpHost = ""
    @Local private var testing = false
    @Local private var error: String?
    @Local private var showAdvanced = false
    @Local private var clientID = Prefs.shared.string(Prefs.Key.googleClientID)
    @Local private var clientSecret = ""
    @Local private var connectingGoogle = false

    private var preset: MailPreset { MailPreset.all.first { $0.id == presetID } ?? MailPreset.all[0] }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MailPreset.all) { p in
                        Button(p.name) { presetID = p.id; error = nil }.buttonStyle(QuietButtonStyle(compact: true, selected: presetID == p.id))
                    }
                }
            }
            if !preset.supported {
                Text(preset.note ?? "").font(.ui(15)).foregroundStyle(Palette.alertFG)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(preset.steps.enumerated()), id: \.offset) { i, s in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("\(i + 1)").font(.ui(12, .semibold)).foregroundStyle(Palette.onAccent).frame(width: 18, height: 18).background(Circle().fill(Palette.accent))
                            Text(s).font(.ui(14)).foregroundStyle(Palette.text2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let u = preset.appPasswordURL, let url = URL(string: u) {
                        Button("Open the app password page") { NSWorkspace.shared.open(url) }.buttonStyle(QuietButtonStyle(compact: true)).padding(.top, 2)
                    }
                    if let n = preset.note { Text(n).font(.ui(13)).foregroundStyle(Palette.text3) }
                }
                Field(title: "Email address", text: $email, placeholder: "you@example.com")
                    .onChange(of: email) { _, v in if let g = MailPreset.guess(email: v), g.supported { presetID = g.id } }
                Field(title: "App password", text: $password, secure: true, placeholder: "Paste it here")
                if preset.id == "custom" {
                    HStack(spacing: 10) {
                        Field(title: "IMAP server", text: $imapHost, placeholder: "imap.example.com")
                        Field(title: "SMTP server", text: $smtpHost, placeholder: "smtp.example.com")
                    }
                }
                HStack(spacing: 10) {
                    Button(testing ? "Checking…" : "Connect") { Task { await connect() } }.buttonStyle(PrimaryButtonStyle())
                        .disabled(testing || email.isEmpty || password.isEmpty || (preset.id == "custom" && (imapHost.isEmpty || smtpHost.isEmpty)))
                    if testing { ProgressView().controlSize(.small) }
                }
                if let e = error { Text(e).font(.ui(14)).foregroundStyle(Palette.alertFG).fixedSize(horizontal: false, vertical: true) }
                Text("Your password goes straight into the macOS Keychain on this Mac. everyday. never sends it anywhere except your mail provider.").font(.ui(13)).foregroundStyle(Palette.text3)
            }
            Button { withAnimation(.easeOut(duration: 0.2)) { showAdvanced.toggle() } } label: {
                HStack(spacing: 4) { Image(systemName: showAdvanced ? "chevron.down" : "chevron.right").font(.system(size: 10)); Text("Advanced: use the Gmail API with your own Google client").font(.ui(13.5)) }.foregroundStyle(Palette.text3)
            }.buttonStyle(.plain)
            if showAdvanced { advanced.transition(.opacity.combined(with: .move(edge: .top))) }
        }
    }

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("For people who already have a Google Cloud OAuth client. Faster sync and real Gmail threads, but you must create the client yourself (see the README).").font(.ui(13.5)).foregroundStyle(Palette.text2)
            Field(title: "OAuth client ID", text: $clientID)
            Field(title: "Client secret", text: $clientSecret, secure: true)
            Button(connectingGoogle ? "Waiting for Google…" : "Sign in with Google") { Task { await connectGoogle() } }.buttonStyle(QuietButtonStyle()).disabled(clientID.isEmpty || connectingGoogle)
        }.padding(14).background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
    }

    private func connect() async {
        testing = true; error = nil; defer { testing = false }
        let addr = email.trimmingCharacters(in: .whitespaces)
        guard addr.contains("@") else { error = "Enter your full email address."; return }
        let p = preset
        let acct = ImapAccount(email: addr, username: addr, presetID: p.id,
                               imapHost: p.id == "custom" ? imapHost.trimmingCharacters(in: .whitespaces) : p.imapHost, imapPort: p.imapPort,
                               smtpHost: p.id == "custom" ? smtpHost.trimmingCharacters(in: .whitespaces) : p.smtpHost, smtpPort: p.smtpPort, smtpSecurity: p.smtpSecurity)
        let pw = password.components(separatedBy: .whitespacesAndNewlines).joined()
        do {
            let count = try await ImapBackend.test(account: acct, password: pw)
            let first = !model.mail.isConnected
            try model.mail.imap.save(account: acct, password: pw)
            if first { model.mail.kind = .imap }
            password = ""
            model.say("Connected to \(addr). \(count) messages in the inbox.")
            onConnected()
            Task { await model.syncMail() }
        } catch let e as ImapError {
            if case .auth = e {
                error = p.id == "gmail" ? "Google rejected that password. Check that it is the 16-character app password (not your normal one), and that IMAP is on in Gmail → Settings → Forwarding and POP/IMAP." : "The server rejected the email address or password. Check the app password and try again."
            } else { error = e.localizedDescription }
        } catch { self.error = error.localizedDescription }
    }

    private func connectGoogle() async {
        connectingGoogle = true; defer { connectingGoogle = false }
        model.auth.clientID = clientID; model.auth.clientSecret = clientSecret
        do {
            let first = !model.mail.isConnected
            _ = try await model.auth.signIn { NSWorkspace.shared.open($0) }
            if first { model.mail.kind = .gmailAPI }
            NSApp.activate(ignoringOtherApps: true)
            model.say("Gmail connected.")
            onConnected()
            Task { await model.syncMail() }
        } catch { model.fail(error, "Gmail") }
    }
}
