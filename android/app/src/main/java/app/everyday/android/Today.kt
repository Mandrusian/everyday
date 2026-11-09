package app.everyday.android

import android.media.MediaPlayer
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.core.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TodayScreen(model: AppModel, onOpen: (Row) -> Unit, onSettings: () -> Unit, onTab: (Tab) -> Unit) {
    val p = pal()
    val now = remember { Calendar.getInstance() }
    val needs = model.rows.filter { it.attention && it.threadId !in model.gone }
    PullToRefreshBox(model.syncing, { model.refresh() }, Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 0.dp, bottom = 32.dp)) {
            item {
                Row(Modifier.fillMaxWidth().statusBarsPadding().padding(top = 10.dp), verticalAlignment = Alignment.CenterVertically) {
                    Wordmark(20); Spacer(Modifier.weight(1f))
                    IconButton(onSettings) { Icon(Icons.Outlined.Settings, "Settings", tint = p.text2) }
                }
                Spacer(Modifier.height(18.dp))
                Text(SimpleDateFormat("EEEE d MMMM", Locale.getDefault()).format(now.time), style = Type.section, color = p.clay)
                Text("${Format.greeting(now.get(Calendar.HOUR_OF_DAY))}${if (model.name.isNotBlank()) ", ${model.name}" else ""}.", style = Type.title, color = p.text, modifier = Modifier.padding(top = 2.dp))
                Spacer(Modifier.height(20.dp))
            }
            item { BriefingCard(model) }
            if (model.replies.isNotEmpty()) item {
                LazyRow(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(model.replies) { r ->
                        Chip(r.label, accent = r.kind == "handled", onClick = {
                            if (r.kind == "handled") { model.handled(r.threadIds); model.replies = model.replies - r }
                            else model.rows.firstOrNull { it.threadId in r.threadIds }?.let(onOpen)
                        })
                    }
                }
            }
            if (needs.isNotEmpty()) {
                item { SectionLabel("Needs you", Modifier.padding(top = 28.dp)) }
                items(needs.take(4), key = { it.threadId }) { r -> MailRowView(r, compact = true, onClick = { onOpen(r) }) }
                if (needs.size > 4) item { TextButton({ onTab(Tab.Inbox) }) { Text("${needs.size - 4} more in Inbox", color = p.clay) } }
            }
            if (model.events.isNotEmpty()) {
                item { SectionLabel("Up next", Modifier.padding(top = 28.dp)) }
                items(model.events.take(4)) { e ->
                    Row(Modifier.padding(vertical = 7.dp)) {
                        Box(Modifier.width(3.dp).height(36.dp).background(p.clay, CircleShape))
                        Column(Modifier.padding(start = 12.dp)) {
                            Text(e.title, style = Type.body, fontWeight = FontWeight.Medium, color = p.text)
                            Text(listOf(e.whenText, e.location).filter { it.isNotBlank() }.joinToString(", "), style = Type.small, color = p.text2)
                        }
                    }
                }
            }
            if (model.tasks.isNotEmpty()) {
                item { SectionLabel("Tasks", Modifier.padding(top = 28.dp)) }
                items(model.tasks.take(3), key = { it.id }) { t -> TaskRow(t, model) }
            }
            if (model.stories.isNotEmpty()) {
                item { SectionLabel("Top story", Modifier.padding(top = 28.dp)) }
                item { StoryRow(model.stories.first()) }
            }
        }
    }
}

@Composable
fun BriefingCard(model: AppModel) {
    val p = pal(); val scope = rememberCoroutineScope()
    var player by remember { mutableStateOf<MediaPlayer?>(null) }
    var loadingVoice by remember { mutableStateOf(false) }
    var paused by remember { mutableStateOf(false) }
    DisposableEffect(Unit) { onDispose { player?.release() } }
    Card(Modifier.animateContentSize(spring(stiffness = Spring.StiffnessMediumLow))) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Daily briefing", style = Type.section, color = p.clay, modifier = Modifier.weight(1f))
            if (model.briefing != null && model.hasAiKey) {
                Pressable({
                    player?.let { audio ->
                        if (paused) { audio.start(); paused = false } else { audio.pause(); paused = true }
                        return@Pressable
                    }
                    scope.launch {
                        loadingVoice = true
                        try {
                            val file = Core.run("speak", json("text" to Format.plain(model.briefing!!))) as String
                            val audio = MediaPlayer()
                            player = audio
                            audio.setOnPreparedListener { loadingVoice = false; paused = false; it.start() }
                            audio.setOnCompletionListener { it.release(); player = null; paused = false }
                            audio.setOnErrorListener { mp, _, _ ->
                                mp.release(); player = null; paused = false; loadingVoice = false
                                model.toast("The voice didn't load."); true
                            }
                            audio.setDataSource(file)
                            audio.prepareAsync()
                        } catch (e: Core.Failure) {
                            player?.release(); player = null; loadingVoice = false
                            model.toast(e.message ?: "The voice didn't load.")
                        } catch (e: java.io.IOException) {
                            player?.release(); player = null; loadingVoice = false
                            model.toast("The voice didn't load.")
                        }
                    }
                }, enabled = !loadingVoice) {
                    Row(Modifier.background(p.claySoft, CircleShape).padding(horizontal = 12.dp, vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                        if (loadingVoice) CircularProgressIndicator(Modifier.size(14.dp), color = p.clay, strokeWidth = 2.dp)
                        else if (player == null || paused) Icon(Icons.Filled.PlayArrow, null, tint = p.clay, modifier = Modifier.size(16.dp))
                        Text(if (loadingVoice) "Preparing…" else if (player == null) "Listen" else if (paused) "Resume" else "Pause", color = p.clay, fontSize = 13.sp, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(start = 4.dp))
                    }
                }
                if (player != null) IconButton({ player?.release(); player = null; paused = false; loadingVoice = false }) {
                    Text("Stop", color = p.clay, fontSize = 13.sp)
                }
            }
        }
        Spacer(Modifier.height(10.dp))
        val text = model.briefing
        when {
            model.writing -> WritingShimmer()
            text == null && !model.hasAiKey -> Text("Add an AI provider key in Settings and your briefing will appear here each morning.", style = Type.body, color = p.text2)
            text == null -> {
                Text("No briefing yet. It writes itself each morning, or press Write briefing.", style = Type.body, color = p.text2)
                Spacer(Modifier.height(14.dp)); PrimaryButton("Write briefing", { model.writeBriefing() })
            }
            else -> {
                Format.sections(text).forEachIndexed { i, s ->
                    if (s.heading != null) Text(s.heading, style = Type.section, color = p.text2, modifier = Modifier.padding(top = if (i == 0) 0.dp else 14.dp, bottom = 4.dp))
                    Text(Format.skim(s.body, p), style = Type.reading, color = p.text)
                }
                Spacer(Modifier.height(12.dp))
                Text("Rewrite", color = p.text3, fontSize = 13.5.sp, modifier = Modifier.padding(vertical = 4.dp).clickableNoRipple { model.writeBriefing() })
            }
        }
    }
}

/** Three soft lines that breathe while the AI writes. */
@Composable
fun WritingShimmer() {
    val p = pal()
    val a by rememberInfiniteTransition(label = "w").animateFloat(0.35f, 0.8f, infiniteRepeatable(tween(900, easing = FastOutSlowInEasing), RepeatMode.Reverse), label = "a")
    Column(verticalArrangement = Arrangement.spacedBy(9.dp)) {
        listOf(1f, 0.92f, 0.6f).forEach { w -> Box(Modifier.fillMaxWidth(w).height(14.dp).alpha(a).background(p.line, CircleShape)) }
        Text("Writing…", style = Type.small, color = p.text3)
    }
}

