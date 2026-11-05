package app.everyday.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.*
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.*
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

enum class Tab(val title: String, val icon: ImageVector, val selectedIcon: ImageVector) {
    Today("Today", Icons.Outlined.Home, Icons.Filled.Home),
    Inbox("Inbox", Icons.Outlined.Email, Icons.Filled.Email),
    News("News", Icons.Outlined.Star, Icons.Filled.Star),
    Tasks("Tasks", Icons.Outlined.CheckCircle, Icons.Filled.CheckCircle),
    Ask("Ask", Icons.Outlined.Search, Icons.Filled.Search),
}

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        Core.open(applicationContext)
        Morning.schedule(applicationContext)
        setContent { EverydayTheme { Root() } }
    }
}

@Composable
fun Root() {
    val scope = rememberCoroutineScope()
    val model = remember { AppModel(scope) }
    LaunchedEffect(Unit) { model.start() }
    val p = pal()
    Box(Modifier.fillMaxSize().background(p.paper)) {
        when {
            !model.ready -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) { Wordmark(34) }
            !model.onboarded -> Onboarding(model)
            else -> Shell(model)
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun Shell(model: AppModel) {
    var tab by rememberSaveable { mutableStateOf(Tab.Today) }
    var openThread by remember { mutableStateOf<Row?>(null) }
    var settings by remember { mutableStateOf(false) }
    val snack = remember { SnackbarHostState() }
    val p = pal()
    LaunchedEffect(model.message) { model.message?.let { snack.showSnackbar(it); model.message = null } }
    BackHandler(tab != Tab.Today && openThread == null) { tab = Tab.Today }

    Scaffold(containerColor = p.paper, snackbarHost = { SnackbarHost(snack) { Snackbar(it, containerColor = p.text, contentColor = p.paper, shape = androidx.compose.foundation.shape.RoundedCornerShape(14.dp)) } },
        bottomBar = { BottomBar(tab, model.rows.count { it.attention && it.threadId !in model.gone }) { tab = it } }) { pad ->
        Box(Modifier.padding(bottom = pad.calculateBottomPadding()).fillMaxSize()) {
            AnimatedContent(tab, transitionSpec = { fadeIn(tween(180)) togetherWith fadeOut(tween(120)) }, label = "tab") { t ->
                when (t) {
                    Tab.Today -> TodayScreen(model, onOpen = { openThread = it }, onSettings = { settings = true }, onTab = { tab = it })
                    Tab.Inbox -> InboxScreen(model, onOpen = { openThread = it })
                    Tab.News -> NewsScreen(model)
                    Tab.Tasks -> TasksScreen(model)
                    Tab.Ask -> AskScreen(model)
                }
            }
        }
    }
    AnimatedVisibility(openThread != null, enter = slideInHorizontally { it } + fadeIn(), exit = slideOutHorizontally { it } + fadeOut()) {
        openThread?.let { r -> ThreadScreen(model, r, onClose = { openThread = null }) }
    }
    if (settings) SettingsSheet(model) { settings = false }
}

@Composable
fun BottomBar(tab: Tab, needs: Int, onTab: (Tab) -> Unit) {
    val p = pal(); val h = LocalHapticFeedback.current
    Column(Modifier.background(p.paper)) {
        Hairline()
        Row(Modifier.fillMaxWidth().navigationBarsPadding().padding(horizontal = 8.dp, vertical = 6.dp), horizontalArrangement = Arrangement.SpaceAround) {
            Tab.entries.forEach { t ->
                val on = t == tab
                Pressable({ if (!on) { h.performHapticFeedback(HapticFeedbackType.TextHandleMove); onTab(t) } }, Modifier.weight(1f), haptic = false) {
                    Column(Modifier.fillMaxWidth().padding(vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        BadgedBox(badge = { if (t == Tab.Inbox && needs > 0) Badge(containerColor = p.clay, contentColor = p.paper) { Text("$needs", fontSize = 10.sp) } }) {
                            Icon(if (on) t.selectedIcon else t.icon, t.title, tint = if (on) p.clay else p.text3, modifier = Modifier.size(24.dp))
                        }
                        Spacer(Modifier.height(3.dp))
                        Text(t.title, fontSize = 11.5.sp, fontWeight = if (on) FontWeight.SemiBold else FontWeight.Medium, color = if (on) p.text else p.text3)
                    }
                }
            }
        }
    }
}
