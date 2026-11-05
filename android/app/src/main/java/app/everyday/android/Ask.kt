package app.everyday.android

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject

data class Turn(val role: String, val text: String, val sources: List<String> = emptyList())

/** Ask everyday.: answers from your mail, tasks and news, says what it used, and can't change anything. */
@Composable
fun AskScreen(model: AppModel) {
    val p = pal(); val scope = rememberCoroutineScope(); val list = rememberLazyListState()
    var turns by remember { mutableStateOf(listOf<Turn>()) }
    var input by remember { mutableStateOf("") }
    var thinking by remember { mutableStateOf(false) }
    fun send(q: String) {
        if (q.isBlank() || thinking) return
        val history = JSONArray(turns.map { t -> JSONObject().put("role", t.role).put("text", t.text) })
        turns = turns + Turn("user", q); input = ""; thinking = true
        scope.launch {
            try {
                val o = Core.run("ask", json("question" to q, "history" to history)) as JSONObject
                val src = o.optJSONArray("sources")?.let { a -> (0 until a.length()).map { a.getJSONObject(it).optString("title") } } ?: emptyList()
                turns = turns + Turn("assistant", o.optString("text"), src)
            } catch (e: Core.Failure) { turns = turns + Turn("assistant", e.message ?: "I couldn't answer that.") }
            thinking = false; list.animateScrollToItem(turns.lastIndex.coerceAtLeast(0))
        }
    }
    Column(Modifier.fillMaxSize().imePadding()) {
        Column(Modifier.statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 22.dp)) {
            Text("Ask", style = Type.title, color = p.text)
            Text("About your mail, calendar, tasks and the news. It reads; it never sends or deletes.", style = Type.small, color = p.text2)
        }
        LazyColumn(Modifier.weight(1f), state = list, contentPadding = PaddingValues(20.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
            if (turns.isEmpty()) item {
                Column(verticalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.padding(top = 12.dp)) {
                    listOf("What needs me today?", "Did Oscar reply about Thursday?", "Anything due this week?").forEach { Chip(it, { send(it) }) }
                }
            }
            items(turns) { t ->
                val mine = t.role == "user"
                Box(Modifier.fillMaxWidth(), contentAlignment = if (mine) Alignment.CenterEnd else Alignment.CenterStart) {
                    Column(Modifier.fillMaxWidth(if (mine) 0.82f else 1f).wrapContentWidth(if (mine) Alignment.End else Alignment.Start)
                        .background(if (mine) p.text else p.raised, RoundedCornerShape(18.dp)).padding(horizontal = 15.dp, vertical = 11.dp).animateContentSize()) {
                        Text(if (mine) androidx.compose.ui.text.AnnotatedString(t.text) else Format.skim(t.text, p), style = if (mine) Type.body else Type.reading.copy(fontSize = 16.sp), color = if (mine) p.paper else p.text)
                        if (t.sources.isNotEmpty()) Text("From: " + t.sources.joinToString(", "), fontSize = 12.sp, color = p.text3, modifier = Modifier.padding(top = 6.dp))
                    }
                }
            }
            if (thinking) item { WritingShimmer() }
        }
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.Bottom) {
            Field("", input, { input = it }, placeholder = if (model.hasAiKey) "Ask anything" else "Add a Gemini key in Settings first", singleLine = false, modifier = Modifier.weight(1f))
            IconButton({ send(input.trim()) }, Modifier.padding(start = 6.dp).background(if (input.isBlank()) p.line else p.clay, RoundedCornerShape(50)), enabled = input.isNotBlank()) { Icon(Icons.AutoMirrored.Filled.Send, "Ask", tint = p.paper) }
        }
    }
}
