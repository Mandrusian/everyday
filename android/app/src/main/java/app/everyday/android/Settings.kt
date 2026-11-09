package app.everyday.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
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

private fun prefList(raw: String): List<String> = runCatching {
    val a = org.json.JSONArray(raw)
    (0 until a.length()).map { a.getString(it).trim() }.filter { it.isNotBlank() }
}.getOrElse { raw.split(',').map(String::trim).filter(String::isNotBlank) }.distinctBy { it.lowercase() }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsSheet(model: AppModel, onClose: () -> Unit) {
    val p = pal(); val scope = rememberCoroutineScope()
    var pane by androidx.compose.runtime.saveable.rememberSaveable { mutableStateOf("General") }
    var name by remember { mutableStateOf(model.name) }
    var ics by remember { mutableStateOf("") }
    var morning by remember { mutableStateOf(false) }
    var hour by remember { mutableIntStateOf(7) }
    var editKey by remember { mutableStateOf(false) }
    var training by remember { mutableStateOf(false) }
    if (training) androidx.compose.ui.window.Dialog({ training = false; scope.launch { model.loadLocal() } }, androidx.compose.ui.window.DialogProperties(usePlatformDefaultWidth = false)) {
        Column(Modifier.fillMaxSize().background(p.paper).systemBarsPadding().padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) { Text("Teach it your taste", style = Type.heading, color = p.text, modifier = Modifier.weight(1f)); TextButton({ training = false }) { Text("Done", color = p.clay) } }
            Box(Modifier.weight(1f)) { Deck(model) }
        }
    }
    LaunchedEffect(Unit) {
        ics = Core.run("getPref", json("key" to "icsUrl")) as String
        morning = Core.run("getPref", json("key" to "morningOn")) == "1"
        hour = (Core.run("getPref", json("key" to "morningHour")) as String).toIntOrNull() ?: 7
    }
    ModalBottomSheet(onClose, containerColor = p.paper, sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)) {
        Column(Modifier.fillMaxHeight(0.94f)) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 22.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Settings", style = Type.heading, color = p.text, modifier = Modifier.weight(1f))
                TextButton(onClose) { Text("Done", color = p.clay) }
            }
            Row(Modifier.horizontalScroll(rememberScrollState()).padding(horizontal = 22.dp, vertical = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                listOf("General", "Briefing", "Accounts", "AI provider", "Interests", "Notifications", "Sync").forEach { title -> Chip(title, { pane = title }, accent = pane == title) }
            }
            Hairline()
            key(pane) { Column(Modifier.weight(1f).verticalScroll(rememberScrollState()).padding(horizontal = 22.dp, vertical = 20.dp).padding(bottom = 28.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                when (pane) {
                    "General" -> {
                        Field("Your first name", name, { name = it; model.name = it.trim(); model.setPref("name", it.trim()) })
                        Spacer(Modifier.height(12.dp))
                        Text("everyday. is free and open source (GPL-3.0). Your mail stays on this phone.", style = Type.small, color = p.text3)
                    }
                    "Briefing" -> BriefingSettings(model)
                    "Accounts" -> {
                        SectionLabel("Mail")
                        if (model.email != null) Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(model.email!!, style = Type.body, color = p.text, modifier = Modifier.weight(1f))
                            QuietButton("Disconnect", { scope.launch { Core.run("disconnectMail"); Core.forget("imap.password.${model.email!!.lowercase()}"); model.email = null; model.loadLocal() } })
                        } else MailSetup(model) {}
                        SectionLabel("Calendar", Modifier.padding(top = 12.dp))
                        Field("Calendar link (.ics)", ics, { ics = it.trim(); model.setPref("icsUrl", it.trim()) }, placeholder = "https://… from Google, Outlook or iCloud", keyboard = KeyboardType.Uri)
                        Text("In Google Calendar: Settings, your calendar, “Secret address in iCal format”. Read-only.", style = Type.small, color = p.text2)
                    }
                    "AI provider" -> {
                        if (model.hasAiKey && !editKey) Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Gemini key saved", style = Type.body, color = p.text, modifier = Modifier.weight(1f))
                            QuietButton("Replace", { editKey = true })
                        } else AiKeySetup(model) { editKey = false }
                    }
                    "Interests" -> {
                        Text("everyday. learns what you like from the categories you pick and the stories you swipe on. It all stays on this phone.", style = Type.small, color = p.text2)
                        SectionLabel("What it has learned")
                        Text(if (model.learned.isEmpty()) "Nothing yet. Swipe through some stories to teach it." else model.learned.joinToString(", "), style = Type.body, color = p.text)
                        TopicListEditor(model, "followedTopics", "Your own topics", "Follow anything by name, like “Formula 1”, “Cairns” or “Rust”. Stories that mention it rise to the top, and it gets its own tab in News.", "Follow a topic", "Follow")
                        SectionLabel("Categories", Modifier.padding(top = 12.dp))
                        TopicPicker(model)
                        QuietButton("Retrain with a swipe deck", { training = true })
                        QuietButton("Reset everything learned", { model.resetInterests() })
                    }
                    "Notifications" -> {
                        SettingSwitch("Morning briefing", "Writes your briefing at this time and sends a notification with the first lines.", morning) { morning = it; model.setPref("morningOn", if (it) "1" else "0") }
                        if (morning) Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            (4..12).forEach { hr -> Chip("$hr:00", { hour = hr; model.setPref("morningHour", "$hr") }, accent = hour == hr) }
                        }
                    }
                    "Sync" -> SyncSection()
                }
            } }
        }
    }
}

@Composable
private fun SettingSwitch(title: String, detail: String, checked: Boolean, enabled: Boolean = true, change: (Boolean) -> Unit) {
    val p = pal()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Column(Modifier.weight(1f)) {
            Text(title, style = Type.body, color = p.text)
            if (detail.isNotBlank()) Text(detail, style = Type.small, color = p.text2)
        }
        Switch(checked, change, enabled = enabled, colors = SwitchDefaults.colors(checkedTrackColor = p.clay, checkedThumbColor = p.paper, uncheckedTrackColor = p.line, uncheckedBorderColor = p.line, uncheckedThumbColor = p.paper))
    }
}

@Composable
private fun BriefingSettings(model: AppModel) {
    val p = pal()
    val titles = listOf(Triple("mail", "Mail that needs me", "Replies owed and deadlines"), Triple("calendar", "Calendar", "Today's events"), Triple("weather", "Weather", "One line"), Triple("news", "News", "A few top stories"), Triple("tasks", "Tasks", "What is open and due"))
    var sections by remember { mutableStateOf(titles.map { it.first }.toSet()) }
    var count by remember { mutableIntStateOf(3) }
    var instructions by remember { mutableStateOf("") }
    var loaded by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        val raw = Core.run("getPref", json("key" to "briefingSections")) as String
        sections = if (raw.isBlank()) titles.map { it.first }.toSet() else prefList(raw).toSet()
        count = (Core.run("getPref", json("key" to "briefingNewsCount")) as String).toIntOrNull()?.coerceIn(0, 8) ?: 3
        instructions = Core.run("getPref", json("key" to "briefingInstructions")) as String
        loaded = true
    }
    Text("Tell everyday. what you want to see each morning. Changes apply the next time a briefing is written.", style = Type.body, color = p.text2)
    if (!loaded) Text("Loading…", style = Type.small, color = p.text3)
    else {
        SectionLabel("Include")
        titles.forEach { (id, title, detail) ->
            SettingSwitch(title, if (id == "weather") "One line · not available on this phone yet" else detail, id in sections, enabled = id != "weather") { on ->
                sections = if (on) sections + id else sections - id
                model.setPref("briefingSections", org.json.JSONArray(titles.map { it.first }.filter { it in sections }).toString())
            }
        }
        SectionLabel("Stories to mention", Modifier.padding(top = 12.dp))
        Text("How many news stories the briefing may cover. Zero leaves news out.", style = Type.small, color = p.text2)
        Row(Modifier.horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            (0..8).forEach { n -> Chip("$n", { count = n; model.setPref("briefingNewsCount", "$n") }, accent = count == n) }
        }
        SectionLabel("In your own words", Modifier.padding(top = 12.dp))
        Text("Standing instructions the AI follows every time. For example: “Skip anything about Hong Kong and chip makers. I care about AI policy, aviation and Australian politics. Keep it under 100 words.”", style = Type.small, color = p.text2)
        Field("Standing instructions for the briefing", instructions, { instructions = it; model.setPref("briefingInstructions", it) }, singleLine = false, modifier = Modifier.heightIn(min = 110.dp))
        TopicListEditor(model, "mutedTopics", "Hide these topics everywhere", "Stories mentioning any of these words disappear from the briefing, Top news and the reader's list.", "Hide a topic", "Add")
        PrimaryButton(if (model.writing) "Writing…" else "Write the briefing now", { model.writeBriefing() }, enabled = !model.writing && model.hasAiKey)
    }
}

@Composable
private fun TopicListEditor(model: AppModel, pref: String, title: String, detail: String, label: String, action: String) {
    val p = pal(); val scope = rememberCoroutineScope()
    var topics by remember(pref) { mutableStateOf(emptyList<String>()) }
    var input by remember(pref) { mutableStateOf("") }
    var loaded by remember(pref) { mutableStateOf(false) }
    var error by remember(pref) { mutableStateOf<String?>(null) }
    var saving by remember(pref) { mutableStateOf(false) }
    LaunchedEffect(pref) { topics = prefList(Core.run("getPref", json("key" to pref)) as String); loaded = true }
    fun save(next: List<String>) { scope.launch {
        saving = true
        try { Core.run("setPref", json("key" to pref, "value" to org.json.JSONArray(next).toString())); topics = next; input = ""; error = null; model.loadLocal() }
        catch (e: Core.Failure) { error = e.message }
        finally { saving = false }
    } }
    SectionLabel(title, Modifier.padding(top = 12.dp))
    Text(detail, style = Type.small, color = p.text2)
    Field(label, input, { input = it }, placeholder = if (action == "Follow") "Add a topic" else "Add a word or phrase")
    QuietButton(action, { val t = input.trim(); if (t.isNotEmpty() && topics.none { it.equals(t, true) }) save(topics + t) }, enabled = loaded && !saving && input.isNotBlank() && topics.none { it.equals(input.trim(), true) })
    topics.forEach { topic ->
        Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(topic, style = Type.body, color = p.text, modifier = Modifier.weight(1f))
            TextButton({ save(topics - topic) }, enabled = !saving) { Text(if (action == "Follow") "Stop following" else "Remove", color = p.clay) }
        }
    }
    error?.let { Text(it, style = Type.small, color = p.clay) }
}


/** Pair with the Mac or Windows PC over Wi‑Fi: scan its code, type it, or show this phone's code. */
@Composable
fun SyncSection() {
    val p = pal(); val scope = rememberCoroutineScope(); val ctx = androidx.compose.ui.platform.LocalContext.current
    val haptic = androidx.compose.ui.platform.LocalHapticFeedback.current
    val st = SyncLink.status
    var code by remember { mutableStateOf<String?>(null) }
    var includeSetup by remember { mutableStateOf(true) }
    var typed by remember { mutableStateOf("") }
    var err by remember { mutableStateOf<String?>(null) }
    fun join(uri: String) = scope.launch {
        try { SyncLink.status = Core.run("syncJoin", json("uri" to uri)) as org.json.JSONObject; err = null; typed = ""; haptic.performHapticFeedback(androidx.compose.ui.hapticfeedback.HapticFeedbackType.LongPress); Core.run("syncNow") }
        catch (e: Core.Failure) { err = e.message }
    }
    val scan = androidx.activity.compose.rememberLauncherForActivityResult(com.journeyapps.barcodescanner.ScanContract()) { r -> r.contents?.let { join(it) } }

    Text("Keep tasks, news topics and handled mail the same on your phone, Mac and PC. Devices talk directly over your Wi‑Fi, encrypted. No server.", style = Type.small, color = p.text2, modifier = Modifier.padding(bottom = 8.dp))
    if (st.optBoolean("paired")) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).background(if (st.optInt("nearby") > 0) p.clay else p.text3, androidx.compose.foundation.shape.CircleShape))
            Spacer(Modifier.width(10.dp))
            Text(if (st.optInt("nearby") == 0) "Paired. Looking for your devices on this Wi‑Fi." else "${st.optInt("nearby")} nearby", style = Type.body, color = p.text, modifier = Modifier.weight(1f))
            QuietButton("Sync now", { scope.launch { runCatching { Core.run("syncNow") } } })
        }
        val devs = st.optJSONArray("devices")
        for (i in 0 until (devs?.length() ?: 0)) {
            val d = devs!!.getJSONObject(i)
            Text("${d.optString("name")} · synced ${android.text.format.DateUtils.getRelativeTimeSpanString(d.optLong("at") * 1000)}", style = Type.small, color = p.text2, modifier = Modifier.padding(top = 4.dp))
        }
        if (!st.isNull("error") && st.optString("error").isNotEmpty()) Text(st.optString("error"), style = Type.small, color = p.clay)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.padding(top = 10.dp)) {
        QuietButton("Scan a code", { scan.launch(com.journeyapps.barcodescanner.ScanOptions().setPrompt("Scan the code in everyday. Settings → Sync").setBeepEnabled(false).setOrientationLocked(false).setDesiredBarcodeFormats(com.journeyapps.barcodescanner.ScanOptions.QR_CODE)) })
        QuietButton(if (code == null) "Show this phone's code" else "Hide code", { scope.launch { code = if (code == null) Core.run("syncPairingUri", json("includeSetup" to includeSetup)) as String else null; SyncLink.start(ctx) } })
    }
    if (code == null) Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(top = 6.dp)) {
        Column(Modifier.weight(1f)) {
            Text("Include my accounts and keys", style = Type.body, color = p.text)
            Text("Quick setup: the new device gets your mail, AI key and settings. The code works once, for 10 minutes.", style = Type.small, color = p.text2)
        }
        Switch(includeSetup, { includeSetup = it }, colors = SwitchDefaults.colors(checkedTrackColor = p.clay, checkedThumbColor = p.paper, uncheckedTrackColor = p.line, uncheckedBorderColor = p.line, uncheckedThumbColor = p.paper))
    }
    androidx.compose.animation.AnimatedVisibility(code != null) {
        code?.let { c -> Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth().padding(top = 12.dp)) {
            androidx.compose.foundation.Image(SyncLink.qr(c).asImageBitmap(), "Pairing code", Modifier.size(220.dp).background(androidx.compose.ui.graphics.Color.White, androidx.compose.foundation.shape.RoundedCornerShape(14.dp)).padding(10.dp))
            Text(if (includeSetup) "Carries your mail password and AI key for 10 minutes. Only show it to your own devices." else "Only show this to your own devices.", style = Type.small, color = p.text3, modifier = Modifier.padding(top = 6.dp))
        } }
    }
    Field("Or paste a code", typed, { typed = it }, placeholder = "everyday-sync:1:…")
    if (typed.isNotBlank()) QuietButton("Join", { join(typed) })
    err?.let { Text(it, style = Type.small, color = p.clay) }
    if (st.optBoolean("paired")) QuietButton("Stop syncing on this phone", { scope.launch { Core.run("syncLeave"); code = null; SyncLink.status = Core.run("syncStatus") as org.json.JSONObject } }, Modifier.padding(top = 8.dp))
}
