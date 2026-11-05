package app.everyday.android

import androidx.compose.animation.*
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.background
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch

/** Four short steps: hello, your name, mail, AI. Each can be skipped and set up later in Settings. */
@Composable
fun Onboarding(model: AppModel) {
    val p = pal(); val scope = rememberCoroutineScope()
    var step by rememberSaveable { mutableIntStateOf(0) }
    var name by remember { mutableStateOf("") }
    fun finish() = scope.launch { Core.run("setPref", json("key" to "onboarded", "value" to "1")); model.onboarded = true }
    Column(Modifier.fillMaxSize().systemBarsPadding().imePadding().padding(24.dp)) {
        Row { repeat(4) { i -> Box(Modifier.weight(1f).padding(horizontal = 2.dp).height(3.dp).background(if (i <= step) p.clay else p.line, androidx.compose.foundation.shape.CircleShape)) } }
        AnimatedContent(step, transitionSpec = { (slideInHorizontally { it / 3 } + fadeIn()) togetherWith (slideOutHorizontally { -it / 3 } + fadeOut()) }, label = "step", modifier = Modifier.weight(1f)) { s ->
            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(top = 48.dp), verticalArrangement = Arrangement.spacedBy(14.dp)) {
                when (s) {
                    0 -> {
                        Wordmark(44)
                        Text("Your mail, news and day, sorted quietly on this phone.", style = Type.title.copy(fontSize = 26.sp), color = p.text)
                        Text("Each morning you get a few sentences on what needs you. Everything else waits.", style = Type.body, color = p.text2)
                    }
                    1 -> {
                        Text("What should we call you?", style = Type.title, color = p.text)
                        Field("", name, { name = it }, placeholder = "First name")
                    }
                    2 -> { Text("Connect your mail", style = Type.title, color = p.text); MailSetup(model) { step = 3 } }
                    else -> { Text("Add an AI key", style = Type.title, color = p.text); AiKeySetup(model) { finish() } }
                }
            }
        }
        when (step) {
            0 -> PrimaryButton("Get started", { step = 1 })
            1 -> PrimaryButton("Continue", { model.name = name.trim(); model.setPref("name", name.trim()); step = 2 }, enabled = name.isNotBlank())
            2 -> TextButton({ step = 3 }, Modifier.fillMaxWidth()) { Text("Skip for now", color = p.text2) }
            else -> TextButton({ finish() }, Modifier.fillMaxWidth()) { Text("Skip for now", color = p.text2) }
        }
    }
}
