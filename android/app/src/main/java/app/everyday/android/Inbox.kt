package app.everyday.android

import androidx.compose.animation.*
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.DateRange
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun InboxScreen(model: AppModel, onOpen: (Row) -> Unit) {
    val p = pal()
    val visible = model.rows.filter { it.threadId !in model.gone }
    val (needs, rest) = visible.partition { it.attention }
    var showAll by rememberSaveable { mutableStateOf(false) }
    PullToRefreshBox(model.syncing, { model.refresh() }, Modifier.fillMaxSize()) {
        LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(bottom = 24.dp)) {
            item {
                Column(Modifier.statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 22.dp, bottom = 6.dp)) {
                    Text("Inbox", style = Type.title, color = p.text)
                    Text(if (model.email == null) "No mail connected" else if (needs.isEmpty()) "Nothing needs you. Swipe right to archive, left to snooze." else "${needs.size} ${if (needs.size == 1) "needs" else "need"} you", style = Type.small, color = p.text2)
                }
            }
            if (model.email == null) item { EmptyNote("Connect your mail", "Open Settings on the Today tab and add an account with an app password.") }
            else if (visible.isEmpty()) item { EmptyNote("All clear", "Pull down to check for new mail.") }
            if (needs.isNotEmpty()) {
                item { SectionLabel("Needs you", Modifier.padding(start = 20.dp, top = 14.dp)) }
                items(needs, key = { it.threadId }) { r -> SwipeRow(model, r, Modifier.animateItem()) { MailRowView(r, onClick = { onOpen(r) }, padded = true) } }
            }
            if (rest.isNotEmpty()) {
                item { SectionLabel("Everything else", Modifier.padding(start = 20.dp, top = 22.dp)) }
                items(if (showAll) rest else rest.take(25), key = { it.threadId }) { r -> SwipeRow(model, r, Modifier.animateItem()) { MailRowView(r, onClick = { onOpen(r) }, padded = true) } }
                if (!showAll && rest.size > 25) item { TextButton({ showAll = true }, Modifier.padding(start = 12.dp)) { Text("Show ${rest.size - 25} more", color = p.clay) } }
            }
        }
    }
}

/** Swipe right to archive, left to snooze until this evening (or tomorrow morning after 5pm). A haptic tick marks the point of no return. */
@Composable
fun SwipeRow(model: AppModel, r: Row, modifier: Modifier = Modifier, content: @Composable () -> Unit) {
    val p = pal(); val h = LocalHapticFeedback.current
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { v ->
        when (v) {
            SwipeToDismissBoxValue.StartToEnd -> { h.performHapticFeedback(HapticFeedbackType.LongPress); model.archive(r.threadId); model.toast("Archived ${r.from}"); true }
            SwipeToDismissBoxValue.EndToStart -> { h.performHapticFeedback(HapticFeedbackType.LongPress); val hour = java.util.Calendar.getInstance().get(java.util.Calendar.HOUR_OF_DAY); model.snooze(r.threadId, if (hour < 17) 18 - hour else 24 + 8 - hour); model.toast("Snoozed ${r.from}"); true }
            else -> false
        }
    }, positionalThreshold = { it * 0.35f })
    SwipeToDismissBox(state, modifier = modifier, backgroundContent = {
        val toArchive = state.dismissDirection == SwipeToDismissBoxValue.StartToEnd
        Box(Modifier.fillMaxSize().background(if (toArchive) p.claySoft else p.raised).padding(horizontal = 24.dp), contentAlignment = if (toArchive) Alignment.CenterStart else Alignment.CenterEnd) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(if (toArchive) Icons.Filled.Check else Icons.Filled.DateRange, null, tint = if (toArchive) p.clay else p.text2, modifier = Modifier.size(20.dp))
                Text(if (toArchive) "Archive" else "Later", color = if (toArchive) p.clay else p.text2, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, modifier = Modifier.padding(start = 6.dp))
            }
        }
    }) { Box(Modifier.background(p.paper)) { content() } }
}

@Composable
fun MailRowView(r: Row, onClick: () -> Unit, compact: Boolean = false, padded: Boolean = false) {
    val p = pal()
    Pressable(onClick, Modifier.fillMaxWidth()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = if (padded) 20.dp else 0.dp, vertical = 11.dp)) {
            Box(Modifier.padding(top = 7.dp).size(7.dp).background(if (r.attention) p.clay else p.paper, CircleShape))
            Column(Modifier.padding(start = 10.dp).weight(1f)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(r.from.ifBlank { r.fromAddress }, fontSize = 15.5.sp, fontWeight = FontWeight.SemiBold, color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    if (r.count > 1) Text("${r.count}", fontSize = 12.sp, color = p.text3, modifier = Modifier.padding(start = 6.dp))
                    Text(Format.shortTime(r.date), fontSize = 12.5.sp, color = p.text3, modifier = Modifier.padding(start = 8.dp))
                }
                Text(r.subject, fontSize = 14.5.sp, color = p.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                if (!compact || r.summary.isNotBlank()) Text(r.summary.ifBlank { r.snippet }, style = Type.small, color = p.text2, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 1.dp))
            }
        }
    }
}
