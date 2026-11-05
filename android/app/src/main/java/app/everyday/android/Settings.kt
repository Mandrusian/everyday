package app.everyday.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch

data class Provider(val name: String, val imap: String, val smtp: String, val smtpPort: Int, val help: String)
val providers = listOf(
    Provider("Gmail", "imap.gmail.com", "smtp.gmail.com", 465, "Make an app password at myaccount.google.com/apppasswords (needs 2-Step Verification)."),
    Provider("iCloud", "imap.mail.me.com", "smtp.mail.me.com", 587, "Make an app-specific password at account.apple.com, under Sign-In and Security."),
    Provider("Outlook", "outlook.office365.com", "smtp.office365.com", 587, "Make an app password in your Microsoft account's security settings."),
    Provider("Fastmail", "imap.fastmail.com", "smtp.fastmail.com", 465, "Make an app password in Fastmail under Settings, Privacy & Security."),
)

/** Connect a mail account. Passwords go straight to the Android Keystore; nothing passes through a server of ours. */
@Composable
fun MailSetup(model: AppModel, onDone: () -> Unit) {
    val p = pal(); val scope = rememberCoroutineScope()
    var prov by remember { mutableStateOf(providers[0]) }
    var email by remember { mutableStateOf("") }
    var pw by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var error by remember { mutableStateOf<String?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) { providers.forEach { pr -> Chip(pr.name, { prov = pr }, accent = pr == prov) } }
        Field("Email address", email, { email = it.trim() }, placeholder = "you@example.com", keyboard = KeyboardType.Email)
        Field("App password", pw, { pw = it }, placeholder = "xxxx xxxx xxxx xxxx", secret = true, keyboard = KeyboardType.Password)
        Text(prov.help, style = Type.small, color = p.text2)
        error?.let { Text(it, style = Type.small, color = androidx.compose.ui.graphics.Color(0xFFB4442E)) }
        PrimaryButton(if (busy) "Connecting…" else "Connect ${prov.name}", {
            busy = true; error = null
            scope.launch {
                try {
                    Core.run("connectMail", json("email" to email, "password" to pw, "imapHost" to prov.imap, "imapPort" to 993, "smtpHost" to prov.smtp, "smtpPort" to prov.smtpPort))
                    model.email = email; pw = ""; model.refresh(); onDone()
                } catch (e: Core.Failure) { error = e.message } finally { busy = false }
            }
        }, enabled = !busy && email.contains("@") && pw.length >= 8)
    }
}

@Composable
fun AiKeySetup(model: AppModel, onDone: () -> Unit) {
    val p = pal(); val scope = rememberCoroutineScope()
    var key by remember { mutableStateOf("") }
    var busy by remember { mutableStateOf(false) }
    var note by remember { mutableStateOf<String?>(null) }
    Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Field("Gemini API key", key, { key = it.trim() }, placeholder = "AIza…", secret = true)
        Text("Free from aistudio.google.com. It sorts your mail, writes the briefing and reads it aloud. It's kept in the Android Keystore.", style = Type.small, color = p.text2)
        note?.let { Text(it, style = Type.small, color = p.text2) }
        PrimaryButton(if (busy) "Checking…" else "Save key", {
            busy = true
            scope.launch {
                try { Core.run("saveAiKey", json("key" to key)); Core.run("aiTest"); model.hasAiKey = true; key = ""; onDone() }
                catch (e: Core.Failure) { note = e.message } finally { busy = false }
            }
        }, enabled = !busy && key.length > 20)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(model: AppModel, onClose: () -> Unit) {
    val p = pal(); val scope = rememberCoroutineScope()
    var name by remember { mutableStateOf(model.name) }
    var ics by remember { mutableStateOf("") }
    var morning by remember { mutableStateOf(false) }
    var hour by remember { mutableIntStateOf(7) }
    var editMail by remember { mutableStateOf(false) }
    var editKey by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        ics = Core.run("getPref", json("key" to "icsUrl")) as String
        morning = Core.run("getPref", json("key" to "morningOn")) == "1"
        hour = (Core.run("getPref", json("key" to "morningHour")) as String).toIntOrNull() ?: 7
    }
    ModalBottomSheet(onClose, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 22.dp).padding(bottom = 40.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Text("Settings", style = Type.heading, color = p.text, modifier = Modifier.padding(bottom = 12.dp))

            SectionLabel("You")
            Field("First name", name, { name = it; model.name = it.trim(); model.setPref("name", it.trim()) }, placeholder = "For the greeting and briefing")

            SectionLabel("Mail", Modifier.padding(top = 18.dp))
            if (model.email != null && !editMail) Row(verticalAlignment = Alignment.CenterVertically) {
                Text(model.email!!, style = Type.body, color = p.text, modifier = Modifier.weight(1f))
                QuietButton("Disconnect", { scope.launch { Core.run("disconnectMail"); Core.forget("imap.password.${model.email!!.lowercase()}"); model.email = null; model.loadLocal() } })
            } else MailSetup(model) { editMail = false }

            SectionLabel("AI", Modifier.padding(top = 18.dp))
            if (model.hasAiKey && !editKey) Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Gemini key saved", style = Type.body, color = p.text, modifier = Modifier.weight(1f))
                QuietButton("Replace", { editKey = true })
            } else AiKeySetup(model) { editKey = false }

            SectionLabel("Calendar", Modifier.padding(top = 18.dp))
            Field("Calendar link (.ics)", ics, { ics = it.trim(); model.setPref("icsUrl", it.trim()) }, placeholder = "https://… from Google, Outlook or iCloud", keyboard = KeyboardType.Uri)
            Text("In Google Calendar: Settings, your calendar, “Secret address in iCal format”. Read-only.", style = Type.small, color = p.text2)

            SectionLabel("Morning briefing", Modifier.padding(top = 18.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f)) {
                    Text("Write it each morning", style = Type.body, color = p.text)
                    Text("A notification at $hour:00 when it's ready.", style = Type.small, color = p.text2)
                }
                Switch(morning, { morning = it; model.setPref("morningOn", if (it) "1" else "0") }, colors = SwitchDefaults.colors(checkedTrackColor = p.clay, checkedThumbColor = p.paper, uncheckedTrackColor = p.line, uncheckedBorderColor = p.line, uncheckedThumbColor = p.paper))
            }
            if (morning) Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 6.dp)) {
                listOf(6, 7, 8, 9).forEach { hr -> Chip("$hr:00", { hour = hr; model.setPref("morningHour", "$hr") }, accent = hour == hr) }
            }
            Spacer(Modifier.height(24.dp))
            Text("everyday. is free and open source (GPL-3.0). Your mail stays on this phone.", style = Type.small, color = p.text3)
        }
    }
}
