package app.everyday.android

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.sp

/** Warm paper, ink and clay: the same palette as the Mac app and the site. Flat colours, no gradients. */
data class Palette(val paper: Color, val raised: Color, val line: Color, val text: Color, val text2: Color, val text3: Color, val clay: Color, val claySoft: Color)

val Light = Palette(Color(0xFFF5F0E4), Color(0xFFFBF8F0), Color(0xFFE3DACA), Color(0xFF24201A), Color(0xFF5B5346), Color(0xFF8A7F6C), Color(0xFFD97856), Color(0xFFF3DFD3))
val Dark = Palette(Color(0xFF1C1A17), Color(0xFF25231F), Color(0xFF38342D), Color(0xFFECE8DF), Color(0xFFA39E92), Color(0xFF8C887D), Color(0xFFE08A6A), Color(0xFF3A2A22))

val LocalPalette = staticCompositionLocalOf { Light }
val Serif = FontFamily.Serif

object Type {
    val title = TextStyle(fontFamily = Serif, fontSize = 30.sp, lineHeight = 36.sp)
    val heading = TextStyle(fontFamily = Serif, fontSize = 21.sp, lineHeight = 27.sp)
    val section = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    val body = TextStyle(fontSize = 16.sp, lineHeight = 23.sp)
    val reading = TextStyle(fontFamily = Serif, fontSize = 17.sp, lineHeight = 26.sp)
    val small = TextStyle(fontSize = 13.5.sp, lineHeight = 18.sp)
}

@Composable
fun EverydayTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val p = if (dark) Dark else Light
    val scheme = if (dark) darkColorScheme(primary = p.clay, background = p.paper, surface = p.paper, onSurface = p.text, onBackground = p.text, surfaceVariant = p.raised, outline = p.line)
                 else lightColorScheme(primary = p.clay, background = p.paper, surface = p.paper, onSurface = p.text, onBackground = p.text, surfaceVariant = p.raised, outline = p.line)
    androidx.compose.runtime.CompositionLocalProvider(LocalPalette provides p) { MaterialTheme(colorScheme = scheme, content = content) }
}
