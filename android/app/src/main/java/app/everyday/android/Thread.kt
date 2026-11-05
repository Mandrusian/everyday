package app.everyday.android

import androidx.activity.compose.BackHandler
import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.*
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.*

/** Readable email text, as MailText on the Mac: link words become links, tracking URLs and link-only lines disappear. */
object MailText {
    private val labelled = Regex("([^\\n<>]*?[^\\s<>|])\\s*<<?(https?://[^\\s<>]+)>>?")
    private val bare = Regex("https?://[^\\s<>()]+")

    fun unwrap(body: String): String {
        val lines = body.replace("\r\n", "\n").split("\n")
        val sb = StringBuilder()
        lines.forEachIndexed { i, l -> if (l.endsWith("  ") && i < lines.size - 1) sb.append(l.trim()).append(' ') else { sb.append(l); if (i < lines.size - 1) sb.append('\n') } }
        return sb.toString().replace(Regex("\\n{3,}"), "\n\n").trim()
    }

    fun annotated(body: String, p: Palette): AnnotatedString = buildAnnotatedString {
        val text = unwrap(body).lines().filterNot { val t = it.trim(); t.startsWith("<http") && t.endsWith(">") && !t.drop(1).contains('<') }.joinToString("\n")
        val linkStyle = TextLinkStyles(SpanStyle(color = p.clay, textDecoration = TextDecoration.Underline))
        fun plain(s: String) {
            var at = 0
            for (m in bare.findAll(s)) {
                append(s.substring(at, m.range.first))
                val host = runCatching { java.net.URI(m.value).host?.removePrefix("www.") }.getOrNull() ?: m.value
                withLink(LinkAnnotation.Url(m.value, linkStyle)) { append(host) }
                at = m.range.last + 1
            }
            append(s.substring(at))
        }
        var last = 0
        for (m in labelled.findAll(text)) {
            var label = m.groupValues[1]; var start = m.groups[1]!!.range.first
            val words = label.split(" ")
            if (words.size > 6) { val keep = words.takeLast(4).joinToString(" "); start += label.length - keep.length; label = keep }
            if (start > last) plain(text.substring(last, start))
            withLink(LinkAnnotation.Url(m.groupValues[2], linkStyle)) { append(label.trim()) }
            last = m.range.last + 1
        }
        if (last < text.length) plain(text.substring(last))
    }
}

data class Msg(val from: String, val fromAddress: String, val date: Long, val body: String, val attachments: List<String>)

@Composable
fun ThreadScreen(model: AppModel, row: Row, onClose: () -> Unit) {
    val p = pal(); val scope = rememberCoroutineScope(); val h = LocalHapticFeedback.current
    var msgs by remember { mutableStateOf(listOf<Msg>()) }
    var menu by remember { mutableStateOf(false) }
    var draft by rememberSaveable(row.threadId) { mutableStateOf("") }
    var pending by remember { mutableStateOf<String?>(null) }
    var countdown by remember { mutableIntStateOf(0) }
    BackHandler { onClose() }
    LaunchedEffect(row.threadId) {
        msgs = Core.list("thread", json("threadId" to row.threadId)).map { o -> Msg(o.optString("from"), o.optString("fromAddress"), o.optLong("date"), o.optString("body"), (0 until (o.optJSONArray("attachments")?.length() ?: 0)).map { o.getJSONArray("attachments").getString(it) }) }
    }
    // Send waits ten seconds so it can be undone; only then does the core send it.
    LaunchedEffect(pending) {
        val body = pending ?: return@LaunchedEffect
        countdown = 10
        while (countdown > 0) { delay(1000); countdown-- }
        try { Core.run("sendReply", json("threadId" to row.threadId, "body" to body)); model.toast("Sent to ${row.from}"); h.performHapticFeedback(HapticFeedbackType.LongPress) }
        catch (e: Core.Failure) { draft = body; model.toast(e.message ?: "The reply didn't send. It's back in the box.") }
        pending = null
    }
    fun act(f: () -> Unit) { h.performHapticFeedback(HapticFeedbackType.LongPress); f(); onClose() }

    Column(Modifier.fillMaxSize().background(p.paper).imePadding()) {
        Row(Modifier.fillMaxWidth().statusBarsPadding().padding(horizontal = 4.dp, vertical = 4.dp), verticalAlignment = Alignment.CenterVertically) {
            IconButton(onClose) { Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = p.text) }
            Spacer(Modifier.weight(1f))
            TextButton({ act { model.archive(row.threadId) } }) { Text("Archive", color = p.text, fontWeight = FontWeight.Medium) }
            Box {
                IconButton({ menu = true }) { Icon(Icons.Filled.MoreVert, "More", tint = p.text) }
                DropdownMenu(menu, { menu = false }, containerColor = p.raised) {
                    DropdownMenuItem({ Text("Later today") }, { menu = false; act { model.snooze(row.threadId, 4) } })
                    DropdownMenuItem({ Text("Tomorrow morning") }, { menu = false; act { val hr = Calendar.getInstance().get(Calendar.HOUR_OF_DAY); model.snooze(row.threadId, 24 + 8 - hr) } })
                    if (!row.security) DropdownMenuItem({ Text("That was me") }, { menu = false; act { model.handled(listOf(row.threadId)) } })
                    DropdownMenuItem({ Text("Move to Trash", color = Color(0xFFB4442E)) }, { menu = false; act { model.archive(row.threadId, trash = true) } })
                }
            }
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, bottom = 20.dp)) {
            item {
                Text(row.subject.ifBlank { "(no subject)" }, style = Type.heading, color = p.text, modifier = Modifier.padding(top = 6.dp, bottom = 10.dp))
                if (row.summary.isNotBlank()) Text(row.summary, style = Type.small, color = p.text2, modifier = Modifier.background(p.raised, RoundedCornerShape(10.dp)).padding(12.dp).fillMaxWidth())
                // Account-security notices get "That was me" up front; everywhere else it's in the menu.
                if (row.security) Card(Modifier.padding(top = 12.dp)) {
                    Text("Was this you?", style = Type.body, fontWeight = FontWeight.SemiBold, color = p.text)
                    Text("If you just signed in or changed a setting, mark it handled. If not, check your account now.", style = Type.small, color = p.text2, modifier = Modifier.padding(top = 2.dp, bottom = 12.dp))
                    PrimaryButton("That was me", { act { model.handled(listOf(row.threadId)) } })
                }
            }
            items(msgs) { m ->
                Column(Modifier.padding(top = 18.dp)) {
                    Row(verticalAlignment = Alignment.Bottom) {
                        Text(m.from.ifBlank { m.fromAddress }, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, color = p.text, modifier = Modifier.weight(1f))
                        Text(SimpleDateFormat("EEE d MMM, H:mm", Locale.getDefault()).format(Date(m.date * 1000)), fontSize = 12.5.sp, color = p.text3)
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(MailText.annotated(m.body, p), style = Type.reading.copy(fontSize = 16.sp, lineHeight = 24.sp), color = p.text)
                    if (m.attachments.isNotEmpty()) Text("Attached: ${m.attachments.joinToString(", ")}", style = Type.small, color = p.text3, modifier = Modifier.padding(top = 8.dp))
                    Hairline(Modifier.padding(top = 18.dp))
                }
            }
        }
        // Reply box, or the undo bar while a reply waits to go.
        AnimatedContent(pending != null, label = "reply") { waiting ->
            if (waiting) Row(Modifier.fillMaxWidth().background(p.text).navigationBarsPadding().padding(horizontal = 20.dp, vertical = 14.dp), verticalAlignment = Alignment.CenterVertically) {
                Text("Sending in $countdown…", color = p.paper, modifier = Modifier.weight(1f))
                Text("Undo", color = p.clay, fontWeight = FontWeight.SemiBold, modifier = Modifier.clickableNoRipple { draft = pending ?: ""; pending = null })
            } else Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.Bottom) {
                Field("", draft, { draft = it }, placeholder = "Reply to ${row.from.substringBefore(' ')}", singleLine = false, modifier = Modifier.weight(1f))
                AnimatedVisibility(draft.isNotBlank()) {
                    IconButton({ pending = draft.trim(); draft = "" }, Modifier.padding(start = 6.dp).background(p.clay, RoundedCornerShape(50))) { Icon(Icons.AutoMirrored.Filled.Send, "Send", tint = p.paper) }
                }
            }
        }
    }
}
