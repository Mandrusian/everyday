package app.everyday.android

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import kotlin.math.abs

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NewsScreen(model: AppModel) {
    val p = pal()
    var mode by rememberSaveable { mutableStateOf(0) }
    PullToRefreshBox(model.syncing, { model.refresh() }, Modifier.fillMaxSize()) {
        Column(Modifier.fillMaxSize()) {
            Column(Modifier.statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 22.dp)) {
                Text("News", style = Type.title, color = p.text)
                Row(Modifier.horizontalScroll(rememberScrollState()).padding(top = 10.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Chip("Top stories", { mode = 0; model.selectNewsTopic(null) }, accent = mode == 0 && model.newsTopic == null)
                    Chip("Teach me", { mode = 1 }, accent = mode == 1)
                    model.followedTopics.forEach { topic -> Chip(topic, { mode = 0; model.selectNewsTopic(topic) }, accent = mode == 0 && model.newsTopic == topic) }
                }
            }
            if (mode == 0) LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 20.dp, end = 20.dp, top = 8.dp, bottom = 24.dp)) {
                if (model.stories.isEmpty()) item { EmptyNote(if (model.newsTopic == null) "No stories yet" else "No stories about ${model.newsTopic} yet", "Pull down to fetch the news.") }
                items(model.stories, key = { it.url }) { s -> StoryRow(s); Hairline() }
            } else Deck(model)
        }
    }
}

fun open(ctx: android.content.Context, url: String) { runCatching { ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url))) } }

@Composable
fun StoryRow(s: Story) {
    val p = pal(); val ctx = LocalContext.current
    Pressable({ open(ctx, s.url) }, Modifier.fillMaxWidth()) {
        Column(Modifier.padding(vertical = 14.dp)) {
            Text(s.title, style = Type.heading.copy(fontSize = 18.sp, lineHeight = 24.sp), color = p.text)
            if (s.summary.isNotBlank()) Text(Format.plain(s.summary), style = Type.small, color = p.text2, maxLines = 2, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 4.dp))
            Text(s.source + if (s.also > 0) ", and ${s.also} more" else "", fontSize = 12.5.sp, color = p.text3, modifier = Modifier.padding(top = 6.dp))
        }
    }
}

/** Swipe right for more like this, left for less, up to love it. The card tilts with your thumb and snaps with a haptic. */
@Composable
fun Deck(model: AppModel) {
    val p = pal(); val h = LocalHapticFeedback.current; val scope = rememberCoroutineScope()
    val cards = model.deck.take(3)
    Box(Modifier.fillMaxSize().padding(20.dp), contentAlignment = Alignment.Center) {
        if (cards.isEmpty()) EmptyNote("You're through the deck", "Your swipes tune Top stories. Pull down for more.")
        cards.reversed().forEachIndexed { i, s ->
            val top = i == cards.size - 1
            key(s.url) {
                val x = remember { Animatable(0f) }; val y = remember { Animatable(0f) }
                var armed by remember { mutableStateOf(false) }
                val depth = cards.size - 1 - i
                Column(Modifier.fillMaxWidth().fillMaxHeight(0.82f)
                    .graphicsLayer { translationX = x.value; translationY = y.value + depth * 22f; rotationZ = x.value / 40f; scaleX = 1f - depth * 0.04f; scaleY = 1f - depth * 0.04f }
                    .background(p.raised, RoundedCornerShape(24.dp)).border(1.dp, p.line, RoundedCornerShape(24.dp))
                    .then(if (top) Modifier.pointerInput(s.url) {
                        detectDragGestures(onDragEnd = {
                            val (dx, dy) = x.value to y.value
                            val r = when { dy < -260 && abs(dy) > abs(dx) -> 2.0; dx > 260 -> 1.0; dx < -260 -> -1.0; else -> 0.0 }
                            scope.launch {
                                if (r == 0.0) { launch { x.animateTo(0f, spring()) }; y.animateTo(0f, spring()) }
                                else { h.performHapticFeedback(HapticFeedbackType.LongPress); launch { x.animateTo(if (r == 2.0) 0f else dx * 4) }; y.animateTo(if (r == 2.0) -2400f else dy * 2); model.react(s, r) }
                            }
                        }) { c, d ->
                            c.consume(); scope.launch { x.snapTo(x.value + d.x); y.snapTo(y.value + d.y) }
                            val past = abs(x.value) > 260 || y.value < -260
                            if (past != armed) { armed = past; if (past) h.performHapticFeedback(HapticFeedbackType.TextHandleMove) }
                        }
                    } else Modifier)
                    .padding(26.dp)) {
                    Text(s.source, style = Type.section, color = p.clay)
                    Spacer(Modifier.height(14.dp))
                    Text(s.title, style = Type.title.copy(fontSize = 27.sp, lineHeight = 34.sp), color = p.text)
                    Spacer(Modifier.height(14.dp))
                    Text(Format.plain(s.summary), style = Type.reading, color = p.text2, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                    val hint = when { y.value < -120 -> "Love it"; x.value > 120 -> "More like this"; x.value < -120 -> "Less like this"; else -> "Swipe right for more, left for less, up to love it" }
                    Text(hint, fontSize = 13.sp, fontWeight = if (abs(x.value) > 120 || y.value < -120) FontWeight.SemiBold else FontWeight.Normal, color = if (abs(x.value) > 120 || y.value < -120) p.clay else p.text3)
                }
            }
        }
    }
}
