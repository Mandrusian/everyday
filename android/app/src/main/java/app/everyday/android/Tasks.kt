package app.everyday.android

import androidx.compose.animation.animateColorAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import java.text.SimpleDateFormat
import java.util.*

@Composable
fun TasksScreen(model: AppModel) {
    val p = pal()
    var input by remember { mutableStateOf("") }
    Column(Modifier.fillMaxSize().imePadding()) {
        Column(Modifier.statusBarsPadding().padding(start = 20.dp, end = 20.dp, top = 22.dp)) {
            Text("Tasks", style = Type.title, color = p.text)
            Text("Type naturally: “Call Oscar Friday 3pm”, “Pay rent every month”.", style = Type.small, color = p.text2)
        }
        LazyColumn(Modifier.weight(1f), contentPadding = PaddingValues(horizontal = 20.dp, vertical = 12.dp)) {
            if (model.tasks.isEmpty()) item { EmptyNote("Nothing to do", "Add something below, or let the briefing suggest tasks from your mail.") }
            items(model.tasks, key = { it.id }) { t ->
                val h = LocalHapticFeedback.current
                val state = rememberSwipeToDismissBoxState(confirmValueChange = { if (it == SwipeToDismissBoxValue.EndToStart) { h.performHapticFeedback(HapticFeedbackType.LongPress); model.deleteTask(t.id); true } else false })
                SwipeToDismissBox(state, enableDismissFromStartToEnd = false, modifier = Modifier.animateItem(), backgroundContent = {
                    Box(Modifier.fillMaxSize().background(Color(0x22B4442E)).padding(end = 20.dp), contentAlignment = Alignment.CenterEnd) { Icon(Icons.Filled.Delete, "Delete", tint = Color(0xFFB4442E)) }
                }) { Box(Modifier.background(p.paper)) { TaskRow(t, model) } }
            }
        }
        Row(Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
            Field("", input, { input = it }, placeholder = "Add a task", modifier = Modifier.weight(1f))
            Spacer(Modifier.width(8.dp))
            QuietButton("Add", { model.addTask(input); input = "" }, enabled = input.isNotBlank())
        }
    }
}

/** Tapping the circle fills it with clay, ticks, and the row leaves a moment later. */
@Composable
fun TaskRow(t: TaskItem, model: AppModel) {
    val p = pal(); val h = LocalHapticFeedback.current
    var done by remember(t.id) { mutableStateOf(false) }
    val fill by animateColorAsState(if (done) p.clay else p.paper, label = "fill")
    LaunchedEffect(done) { if (done) { kotlinx.coroutines.delay(450); model.toggleTask(t.id) } }
    Row(Modifier.fillMaxWidth().padding(vertical = 11.dp), verticalAlignment = Alignment.CenterVertically) {
        Pressable({ h.performHapticFeedback(HapticFeedbackType.LongPress); done = true }, haptic = false) {
            Box(Modifier.size(24.dp).background(fill, CircleShape).border(1.5.dp, if (done) p.clay else p.text3, CircleShape), contentAlignment = Alignment.Center) {
                if (done) Icon(Icons.Filled.Check, null, tint = p.paper, modifier = Modifier.size(15.dp))
            }
        }
        Column(Modifier.padding(start = 14.dp).weight(1f)) {
            Text(t.title, style = Type.body, color = if (done) p.text3 else p.text)
            t.due?.let { d -> Text(SimpleDateFormat("EEE d MMM, H:mm", Locale.getDefault()).format(Date(d * 1000)), fontSize = 12.5.sp, color = if (d * 1000 < System.currentTimeMillis()) p.clay else p.text3) }
        }
    }
}
