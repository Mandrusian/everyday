package app.everyday.android

import android.content.Context
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.*
import androidx.glance.action.clickable
import androidx.glance.appwidget.*
import androidx.glance.action.actionStartActivity
import androidx.glance.color.ColorProvider
import androidx.glance.layout.*
import androidx.glance.text.*
import org.json.JSONArray
import org.json.JSONObject
import java.time.LocalDate
import java.time.format.TextStyle as JTextStyle
import java.util.Locale

/**
 * Home screen widgets. The app writes a small snapshot after each load; widgets only read it,
 * so they never call the network or the core. Flat paper, ink and clay, like the Mac widgets.
 */
object WidgetSnapshot {
    private const val KEY = "snapshot"
    private fun prefs(ctx: Context) = ctx.getSharedPreferences("widgets", Context.MODE_PRIVATE)

    suspend fun save(ctx: Context, briefing: String?, rows: List<Row>, tasks: List<TaskItem>, events: List<Event>) {
        val o = JSONObject()
            .put("brief", briefing?.let { Format.plain(it) } ?: "")
            .put("needs", JSONArray(rows.filter { it.attention }.take(4).map { JSONObject().put("from", it.from).put("text", it.summary.ifEmpty { it.subject }) }))
            .put("needCount", rows.count { it.attention })
            .put("tasks", JSONArray(tasks.take(6).map { it.title }))
            .put("events", JSONArray(events.take(4).map { JSONObject().put("title", it.title).put("when", it.whenText) }))
        prefs(ctx).edit().putString(KEY, o.toString()).apply()
        listOf(MonthWidget(), BriefWidget(), NeedsWidget(), TasksWidget()).forEach { runCatching { it.updateAll(ctx) } }
    }

    fun load(ctx: Context): JSONObject = runCatching { JSONObject(prefs(ctx).getString(KEY, "{}")!!) }.getOrDefault(JSONObject())
}

private object W {
    val paper = ColorProvider(Light.paper, Dark.paper)
    val text = ColorProvider(Light.text, Dark.text)
    val muted = ColorProvider(Light.text2, Dark.text2)
    val faint = ColorProvider(Light.text3, Dark.text3)
    val clay = ColorProvider(Light.clay, Dark.clay)
    val onClay = ColorProvider(Color.White, Color(0xFF1C1A17))
}

@Composable
private fun WCard(content: @Composable ColumnScope.() -> Unit) = Column(
    GlanceModifier.fillMaxSize().cornerRadius(22.dp).background(W.paper).padding(16.dp).clickable(actionStartActivity<MainActivity>()),
    content = content,
)

@Composable private fun Heading(t: String) = Text(t, style = TextStyle(color = W.clay, fontSize = 12.sp, fontWeight = FontWeight.Medium), maxLines = 1)
@Composable private fun Gap(h: Int = 6) = Spacer(GlanceModifier.height(h.dp))
@Composable private fun Empty(t: String) = Text(t, style = TextStyle(color = W.faint, fontSize = 13.sp))

private fun JSONArray?.objs() = (0 until (this?.length() ?: 0)).map { this!!.getJSONObject(it) }
private fun JSONArray?.strs() = (0 until (this?.length() ?: 0)).map { this!!.getString(it) }

/** Apple-style month: weekday initials, today in a clay circle, next events below when there's room. */
class MonthWidget : GlanceAppWidget() {
    override val sizeMode = SizeMode.Exact
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = WidgetSnapshot.load(context)
        provideContent {
            val size = LocalSize.current
            val today = LocalDate.now()
            val first = today.withDayOfMonth(1)
            val lead = first.dayOfWeek.value % 7 // Sunday first
            val cells = (List(lead) { 0 } + (1..today.lengthOfMonth()).toList()).let { it + List((7 - it.size % 7) % 7) { 0 } }
            val cell = 22.dp
            WCard {
                Row(GlanceModifier.fillMaxWidth()) {
                    Text(today.month.getDisplayName(JTextStyle.FULL, Locale.getDefault()), style = TextStyle(color = W.clay, fontSize = 13.sp, fontWeight = FontWeight.Bold))
                    Spacer(GlanceModifier.defaultWeight())
                    Text("${today.year}", style = TextStyle(color = W.faint, fontSize = 12.sp))
                }
                Gap(6)
                Row(GlanceModifier.fillMaxWidth()) {
                    listOf("S", "M", "T", "W", "T", "F", "S").forEach {
                        Text(it, GlanceModifier.defaultWeight(), style = TextStyle(color = W.faint, fontSize = 10.sp, fontWeight = FontWeight.Medium, textAlign = TextAlign.Center))
                    }
                }
                cells.chunked(7).forEach { week ->
                    Row(GlanceModifier.fillMaxWidth().padding(vertical = 1.dp)) {
                        week.forEach { d ->
                            Box(GlanceModifier.defaultWeight(), contentAlignment = Alignment.Center) {
                                if (d == today.dayOfMonth) Box(GlanceModifier.size(cell).cornerRadius(11.dp).background(W.clay), contentAlignment = Alignment.Center) {
                                    Text("$d", style = TextStyle(color = W.onClay, fontSize = 11.sp, fontWeight = FontWeight.Bold))
                                } else Box(GlanceModifier.size(cell), contentAlignment = Alignment.Center) {
                                    Text(if (d == 0) "" else "$d", style = TextStyle(color = if (today.withDayOfMonth(maxOf(1, d)).dayOfWeek.value >= 6) W.muted else W.text, fontSize = 11.sp))
                                }
                            }
                        }
                    }
                }
                if (size.height > 260.dp) {
                    Gap(10); Heading("Up next")
                    val ev = snap.optJSONArray("events").objs()
                    if (ev.isEmpty()) Empty("Nothing else today.")
                    ev.forEach { e ->
                        Gap(4)
                        Row { Text(e.optString("when"), GlanceModifier.width(70.dp), style = TextStyle(color = W.muted, fontSize = 12.sp), maxLines = 1)
                              Text(e.optString("title"), style = TextStyle(color = W.text, fontSize = 13.sp), maxLines = 1) }
                    }
                }
            }
        }
    }
}

class BriefWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val brief = WidgetSnapshot.load(context).optString("brief")
        provideContent {
            WCard {
                Row(GlanceModifier.fillMaxWidth()) { Heading("Your day"); Spacer(GlanceModifier.defaultWeight()); Text("everyday.", style = TextStyle(color = W.faint, fontSize = 11.sp, fontFamily = FontFamily.Serif)) }
                Gap(8)
                if (brief.isBlank()) Empty("Open everyday. to write this morning's briefing.")
                else Text(brief, style = TextStyle(color = W.text, fontSize = 15.sp, fontFamily = FontFamily.Serif), maxLines = 7)
            }
        }
    }
}

class NeedsWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val snap = WidgetSnapshot.load(context)
        provideContent {
            WCard {
                Row(verticalAlignment = Alignment.Bottom) {
                    Text("${snap.optInt("needCount")}", style = TextStyle(color = W.clay, fontSize = 30.sp, fontWeight = FontWeight.Medium))
                    Spacer(GlanceModifier.width(6.dp))
                    Text("need you", GlanceModifier.padding(bottom = 5.dp), style = TextStyle(color = W.muted, fontSize = 13.sp))
                }
                val needs = snap.optJSONArray("needs").objs()
                if (needs.isEmpty()) { Gap(); Empty("All clear.") }
                needs.forEach { n ->
                    Gap(6)
                    Text(n.optString("from"), style = TextStyle(color = W.text, fontSize = 13.sp, fontWeight = FontWeight.Bold), maxLines = 1)
                    Text(n.optString("text"), style = TextStyle(color = W.muted, fontSize = 12.sp), maxLines = 2)
                }
            }
        }
    }
}

class TasksWidget : GlanceAppWidget() {
    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val tasks = WidgetSnapshot.load(context).optJSONArray("tasks").strs()
        provideContent {
            WCard {
                Heading("Tasks")
                if (tasks.isEmpty()) { Gap(); Empty("Nothing open.") }
                tasks.forEach { t ->
                    Gap(6)
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box(GlanceModifier.size(12.dp).cornerRadius(6.dp).background(W.clay)) {}
                        Spacer(GlanceModifier.width(8.dp))
                        Text(t, style = TextStyle(color = W.text, fontSize = 13.sp), maxLines = 1)
                    }
                }
            }
        }
    }
}

class MonthReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = MonthWidget() }
class BriefReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = BriefWidget() }
class NeedsReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = NeedsWidget() }
class TasksReceiver : GlanceAppWidgetReceiver() { override val glanceAppWidget: GlanceAppWidget = TasksWidget() }
