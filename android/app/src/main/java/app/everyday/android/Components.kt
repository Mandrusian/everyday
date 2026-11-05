package app.everyday.android

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.composed
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

@Composable fun pal() = LocalPalette.current

@Composable
fun Wordmark(size: Int = 22) {
    val p = pal()
    Text(buildAnnotatedString { append("everyday"); withStyle(SpanStyle(color = p.clay)) { append(".") } }, style = TextStyle(fontFamily = Serif, fontSize = size.sp, color = p.text))
}

@Composable
fun SectionLabel(text: String, modifier: Modifier = Modifier) {
    Text(text, style = Type.section, color = pal().clay, modifier = modifier.padding(bottom = 8.dp))
}

/** Springs down a touch when pressed, like the Mac app's buttons, with a light haptic tick on tap. */
@Composable
fun Pressable(onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true, haptic: Boolean = true, content: @Composable BoxScope.() -> Unit) {
    val src = remember { MutableInteractionSource() }
    val pressed by src.collectIsPressedAsState()
    val scale by animateFloatAsState(if (pressed && enabled) 0.97f else 1f, spring(stiffness = 900f), label = "press")
    val h = LocalHapticFeedback.current
    Box(modifier.scale(scale).clickable(src, null, enabled) { if (haptic) h.performHapticFeedback(HapticFeedbackType.TextHandleMove); onClick() }, content = content)
}

@Composable
fun PrimaryButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val p = pal()
    Pressable(onClick, modifier, enabled) {
        Box(Modifier.fillMaxWidth().background(if (enabled) p.text else p.line, RoundedCornerShape(14.dp)).padding(vertical = 15.dp), contentAlignment = Alignment.Center) {
            Text(text, color = p.paper, fontSize = 16.sp, fontWeight = FontWeight.SemiBold)
        }
    }
}

@Composable
fun QuietButton(text: String, onClick: () -> Unit, modifier: Modifier = Modifier, enabled: Boolean = true) {
    val p = pal()
    Pressable(onClick, modifier, enabled) {
        Box(Modifier.border(1.dp, p.line, RoundedCornerShape(50)).padding(horizontal = 16.dp, vertical = 9.dp), contentAlignment = Alignment.Center) {
            Text(text, color = if (enabled) p.text else p.text3, fontSize = 14.5.sp, fontWeight = FontWeight.Medium)
        }
    }
}

@Composable
fun Chip(text: String, onClick: () -> Unit, accent: Boolean = false) {
    val p = pal()
    Pressable(onClick) {
        Text(text, fontSize = 14.sp, fontWeight = FontWeight.Medium, color = if (accent) p.clay else p.text,
            maxLines = 1, softWrap = false, modifier = Modifier.background(if (accent) p.claySoft else p.raised, RoundedCornerShape(50)).border(1.dp, if (accent) p.claySoft else p.line, RoundedCornerShape(50)).padding(horizontal = 14.dp, vertical = 8.dp))
    }
}

@Composable
fun Field(label: String, value: String, onChange: (String) -> Unit, placeholder: String = "", secret: Boolean = false, keyboard: KeyboardType = KeyboardType.Text, singleLine: Boolean = true, modifier: Modifier = Modifier) {
    val p = pal()
    Column(modifier) {
        if (label.isNotEmpty()) Text(label, style = Type.small, color = p.text2, modifier = Modifier.padding(bottom = 6.dp))
        BasicTextField(value, onChange, singleLine = singleLine, textStyle = Type.body.copy(color = p.text), cursorBrush = SolidColor(p.clay),
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None,
            keyboardOptions = KeyboardOptions(keyboardType = keyboard),
            decorationBox = { inner ->
                Box(Modifier.fillMaxWidth().background(p.raised, RoundedCornerShape(12.dp)).border(1.dp, p.line, RoundedCornerShape(12.dp)).padding(horizontal = 14.dp, vertical = 13.dp)) {
                    if (value.isEmpty()) Text(placeholder, style = Type.body, color = p.text3)
                    inner()
                }
            })
    }
}

@Composable
fun Card(modifier: Modifier = Modifier, content: @Composable ColumnScope.() -> Unit) {
    val p = pal()
    Column(modifier.fillMaxWidth().background(p.raised, RoundedCornerShape(18.dp)).border(1.dp, p.line, RoundedCornerShape(18.dp)).padding(18.dp), content = content)
}

@Composable
fun Hairline(modifier: Modifier = Modifier) { Box(modifier.fillMaxWidth().height(1.dp).background(pal().line)) }

@Composable
fun EmptyNote(title: String, body: String, modifier: Modifier = Modifier) {
    val p = pal()
    Column(modifier.fillMaxWidth().padding(vertical = 48.dp, horizontal = 24.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(title, style = Type.heading, color = p.text)
        Spacer(Modifier.height(6.dp))
        Text(body, style = Type.body, color = p.text2, textAlign = androidx.compose.ui.text.style.TextAlign.Center)
    }
}

fun Modifier.clickableNoRipple(onClick: () -> Unit): Modifier = composed { clickable(remember { MutableInteractionSource() }, null, onClick = onClick) }
