package app.everyday.android

import androidx.compose.animation.*
import androidx.compose.foundation.layout.Box
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
        Row { repeat(6) { i -> Box(Modifier.weight(1f).padding(horizontal = 2.dp).height(3.dp).background(if (i <= step) p.clay else p.line, androidx.compose.foundation.shape.CircleShape)) } }
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
                    2 -> {
                        Text("What are you into?", style = Type.title, color = p.text)
                        Text("Pick a few. You'll fine-tune it next by swiping stories, and you can change it any time in Settings.", style = Type.body, color = p.text2)
                        TopicPicker(model)
                    }
                    3 -> {
                        Text("Teach it your taste", style = Type.title, color = p.text)
                        Text("Swipe right for more like this, left for less, up to love it.", style = Type.body, color = p.text2)
                        Box(Modifier.fillMaxWidth().height(480.dp)) { Deck(model) }
                    }
                    4 -> { Text("Connect your mail", style = Type.title, color = p.text); MailSetup(model) { step = 5 } }
                    else -> { Text("Add an AI key", style = Type.title, color = p.text); AiKeySetup(model) { finish() } }
                }
            }
        }
        when (step) {
            0 -> Column {
                PrimaryButton("Get started", { step = 1 })
                val scan = androidx.activity.compose.rememberLauncherForActivityResult(com.journeyapps.barcodescanner.ScanContract()) { r -> r.contents?.let { uri -> scope.launch {
                    try { SyncLink.status = Core.run("syncJoin", json("uri" to uri)) as org.json.JSONObject; model.toast("Paired. Fetching your setup…") } catch (e: Core.Failure) { model.toast(e.message ?: "That code didn't work.") }
                } } }
                TextButton({ scan.launch(com.journeyapps.barcodescanner.ScanOptions().setPrompt("On your Mac or PC: Settings → Sync → Show pairing code").setBeepEnabled(false).setOrientationLocked(false).setDesiredBarcodeFormats(com.journeyapps.barcodescanner.ScanOptions.QR_CODE)) }, Modifier.fillMaxWidth()) {
                    Text("Set up from my other device", color = p.clay)
                }
            }
            1 -> PrimaryButton("Continue", { model.name = name.trim(); model.setPref("name", name.trim()); step = 2 }, enabled = name.isNotBlank())
            2 -> PrimaryButton("Continue", { model.saveTopics(); step = 3 })
            3 -> if (model.deck.isEmpty()) PrimaryButton("Continue", { step = 4 }) else TextButton({ step = 4 }, Modifier.fillMaxWidth()) { Text("Skip", color = p.text2) }
            4 -> TextButton({ step = 5 }, Modifier.fillMaxWidth()) { Text("Skip for now", color = p.text2) }
            else -> TextButton({ finish() }, Modifier.fillMaxWidth()) { Text("Skip for now", color = p.text2) }
        }
    }
}
