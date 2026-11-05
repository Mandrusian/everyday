package app.everyday.android

import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.text.withStyle

/** Briefing text: `## ` headings and the seven skim-reading highlight kinds, the same as the Mac app (Briefing.sections). */
object Format {
    data class Section(val heading: String?, val body: String)

    private val tag = Regex("<<([uadpmnl])\\|(.*?)>>", RegexOption.DOT_MATCHES_ALL)
    private val openTag = Regex("<<[uadpmnl]\\|")

    fun sections(text: String): List<Section> {
        val out = mutableListOf<Section>(); var heading: String? = null; val lines = mutableListOf<String>()
        fun flush() { val b = lines.joinToString("\n").trim(); if (b.isNotEmpty()) out += Section(heading, b); lines.clear() }
        for (line in text.lines()) {
            val t = line.trim()
            if (t.startsWith("## ")) { flush(); heading = t.removePrefix("## ").trim(' ', '#', ':') } else lines += line
        }
        flush(); return out
    }

    fun plain(text: String): String = tag.replace(text) { it.groupValues[2] }.replace(openTag, "").replace(">>", "")
        .lines().filterNot { it.trim().startsWith("## ") }.joinToString("\n")

    /** Highlights as styled spans. Colours stay in the paper palette: no bright boxes, just ink weight and a few warm tints. */
    fun skim(text: String, p: Palette): AnnotatedString = buildAnnotatedString {
        var at = 0
        for (m in tag.findAll(text)) {
            append(clean(text.substring(at, m.range.first)))
            val content = m.groupValues[2]
            if (content.trim(' ', '.', '…', '\n').isNotEmpty()) withStyle(style(m.groupValues[1], p)) { append(content) }
            at = m.range.last + 1
        }
        append(clean(text.substring(at)))
    }

    private fun clean(s: String) = s.replace(openTag, "").replace(">>", "")

    private fun style(kind: String, p: Palette): SpanStyle = when (kind) {
        "u" -> SpanStyle(color = Color(0xFFB4442E), fontWeight = FontWeight.SemiBold)
        "a" -> SpanStyle(color = p.clay, fontWeight = FontWeight.SemiBold)
        "d" -> SpanStyle(color = Color(0xFF3F6E8C), fontWeight = FontWeight.Medium)
        "p" -> SpanStyle(fontWeight = FontWeight.SemiBold)
        "m" -> SpanStyle(color = Color(0xFF4E7A47), fontWeight = FontWeight.Medium)
        "n" -> SpanStyle(fontWeight = FontWeight.Medium, fontFeatureSettings = "tnum")
        "l" -> SpanStyle(fontStyle = FontStyle.Italic, textDecoration = TextDecoration.None)
        else -> SpanStyle()
    }

    fun greeting(hour: Int) = when (hour) { in 4..11 -> "Good morning"; in 12..17 -> "Good afternoon"; else -> "Good evening" }

    /** "2h", "Yesterday", "Tue", "3 Mar": short times for list rows. */
    fun shortTime(epoch: Long): String {
        val now = System.currentTimeMillis() / 1000; val d = now - epoch
        val cal = java.util.Calendar.getInstance(); val that = java.util.Calendar.getInstance().apply { timeInMillis = epoch * 1000 }
        return when {
            d < 60 -> "now"
            d < 3600 -> "${d / 60}m"
            cal.get(java.util.Calendar.DAY_OF_YEAR) == that.get(java.util.Calendar.DAY_OF_YEAR) && cal.get(java.util.Calendar.YEAR) == that.get(java.util.Calendar.YEAR) ->
                java.text.SimpleDateFormat("H:mm", java.util.Locale.getDefault()).format(that.time)
            d < 86400 * 2 -> "Yesterday"
            d < 86400 * 6 -> java.text.SimpleDateFormat("EEE", java.util.Locale.getDefault()).format(that.time)
            else -> java.text.SimpleDateFormat("d MMM", java.util.Locale.getDefault()).format(that.time)
        }
    }
}
