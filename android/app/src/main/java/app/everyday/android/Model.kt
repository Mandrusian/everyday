package app.everyday.android

import androidx.compose.runtime.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import org.json.JSONObject

data class Row(val threadId: String, val from: String, val fromAddress: String, val subject: String, val snippet: String, val summary: String, val attention: Boolean, val category: String, val count: Int, val date: Long, val security: Boolean)
data class Story(val title: String, val source: String, val url: String, val summary: String, val also: Int)
data class TaskItem(val id: String, val title: String, val due: Long?)
data class Reply(val label: String, val kind: String, val threadIds: List<String>, val text: String)
/** The same topics as the Mac app (NewsCategory). */
val TOPICS = listOf("world" to "World", "politics" to "Politics", "australia" to "Australia", "business" to "Business", "economy" to "Economy", "technology" to "Technology", "ai" to "AI",
    "science" to "Science", "space" to "Space", "health" to "Health", "climate" to "Climate", "sport" to "Sport", "gaming" to "Gaming", "aviation" to "Aviation", "entertainment" to "Entertainment",
    "film" to "Film and TV", "music" to "Music", "books" to "Books", "design" to "Design", "food" to "Food", "travel" to "Travel")

data class Event(val title: String, val whenText: String, val location: String)

/** Everything the screens show. One instance for the app; each load calls the Rust core off the main thread. */
class AppModel(private val scope: CoroutineScope) {
    var ready by mutableStateOf(false)
    var email by mutableStateOf<String?>(null)
    var hasAiKey by mutableStateOf(false)
    var name by mutableStateOf("")
    var onboarded by mutableStateOf(false)

    var rows by mutableStateOf(listOf<Row>())
    var stories by mutableStateOf(listOf<Story>())
    var deck by mutableStateOf(listOf<Story>())
    var tasks by mutableStateOf(listOf<TaskItem>())
    var events by mutableStateOf(listOf<Event>())
    var briefing by mutableStateOf<String?>(null)
    var replies by mutableStateOf(listOf<Reply>())
    var writing by mutableStateOf(false)
    var syncing by mutableStateOf(false)
    var message by mutableStateOf<String?>(null)
    /** Threads acted on this session: hidden at once, before the core confirms. */
    var gone by mutableStateOf(setOf<String>())

    var topics by mutableStateOf(setOf<String>())
    var learned by mutableStateOf(listOf<String>())

    fun toggleTopic(id: String) = scope.launch {
        val adding = id !in topics
        topics = if (adding) topics + id else topics - id
        Core.run("setPref", json("key" to "categories", "value" to topics.joinToString(",")))
        if (adding && onboarded) Core.run("seedInterests", json("categories" to org.json.JSONArray(listOf(id))))
    }
    fun saveTopics() = scope.launch { Core.run("seedInterests", json("categories" to org.json.JSONArray(topics.toList()))); loadLocal() }
    fun resetInterests() = scope.launch { Core.run("resetInterests"); Core.run("seedInterests", json("categories" to org.json.JSONArray(topics.toList()))); loadLocal(); toast("Started over from your topics") }

    fun toast(m: String) { message = m }

    fun start() = scope.launch {
        val s = Core.run("state") as JSONObject
        email = s.optString("email").takeIf { s.has("email") && !s.isNull("email") }
        hasAiKey = s.optBoolean("hasAiKey"); name = s.optString("name")
        onboarded = (Core.run("getPref", json("key" to "onboarded")) as? String) == "1"
        topics = ((Core.run("getPref", json("key" to "categories")) as? String) ?: "").split(",").filter { it.isNotBlank() }.toSet()
        (Core.run("lastBriefing") as? JSONObject)?.let { briefing = it.optString("text").ifEmpty { null } }
        loadLocal(); ready = true
        refresh()
    }

    suspend fun loadLocal() {
        rows = Core.list("inbox").map { Row(it.getString("threadId"), it.optString("from"), it.optString("fromAddress"), it.optString("subject"), it.optString("snippet"), it.optString("summary"), it.optBoolean("attention"), it.optString("category"), it.optInt("count", 1), it.optLong("date"), it.optBoolean("security")) }
        stories = Core.list("stories").map(::story)
        deck = Core.list("swipeDeck").map(::story)
        learned = (Core.run("topInterests") as? org.json.JSONArray)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: emptyList()
        tasks = Core.list("tasks").map { TaskItem(it.getString("id"), it.getString("title"), if (it.isNull("due")) null else it.optLong("due")) }
    }

    private fun story(o: JSONObject) = Story(o.optString("title"), o.optString("source"), o.optString("url"), o.optString("summary"), o.optInt("also"))

    /** Pull to refresh: mail, news and the calendar together. Failures say what went wrong in plain words. */
    fun refresh() = scope.launch {
        if (syncing) return@launch
        syncing = true
        try {
            if (email != null) try { Core.run("syncMail") } catch (e: Core.Failure) { toast(e.message ?: "Mail didn't sync.") }
            try { Core.run("newsRefresh") } catch (_: Exception) {}
            events = try { Core.list("upcoming").map { Event(it.optString("title"), it.optString("when"), it.optString("location")) } } catch (_: Exception) { events }
            loadLocal()
        } finally { syncing = false }
    }

    fun writeBriefing(short: Boolean = false) = scope.launch {
        if (writing) return@launch
        writing = true
        try {
            val text = Core.run("briefing") as String
            briefing = text
            replies = Core.list("quickReplies", json("briefing" to text)).map { o -> Reply(o.optString("label"), o.optString("kind"), (0 until (o.optJSONArray("threadIds")?.length() ?: 0)).map { o.getJSONArray("threadIds").getString(it) }, o.optString("text")) }
        } catch (e: Core.Failure) { toast(e.message ?: "The briefing couldn't be written.") } finally { writing = false }
    }

    fun handled(threadIds: List<String>) = scope.launch {
        gone = gone + threadIds
        Core.run("markHandled", json("threadIds" to org.json.JSONArray(threadIds))); loadLocal()
    }

    fun archive(threadId: String, trash: Boolean = false) = scope.launch {
        gone = gone + threadId
        try { Core.run(if (trash) "trash" else "archive", json("threadId" to threadId)); loadLocal() }
        catch (e: Core.Failure) { gone = gone - threadId; toast(e.message ?: "That didn't work.") }
    }

    fun snooze(threadId: String, hours: Int) = scope.launch { gone = gone + threadId; Core.run("snooze", json("threadId" to threadId, "hours" to hours)); loadLocal() }

    fun addTask(input: String) = scope.launch { if (input.isNotBlank()) { Core.run("addTask", json("input" to input)); loadLocal() } }
    fun toggleTask(id: String) = scope.launch { Core.run("toggleTask", json("id" to id)); loadLocal() }
    fun deleteTask(id: String) = scope.launch { Core.run("deleteTask", json("id" to id)); loadLocal() }

    fun react(s: Story, reaction: Double) = scope.launch {
        deck = deck.filter { it.url != s.url }
        Core.run("react", json("url" to s.url, "title" to s.title, "source" to s.source, "reaction" to reaction))
        learned = (Core.run("topInterests") as? org.json.JSONArray)?.let { a -> (0 until a.length()).map { a.getString(it) } } ?: learned
    }

    fun setPref(key: String, value: String) = scope.launch { Core.run("setPref", json("key" to key, "value" to value)) }
}
