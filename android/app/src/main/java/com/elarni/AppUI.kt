package com.elarni

import android.content.res.Configuration
import android.graphics.BitmapFactory
import android.util.Base64
import androidx.activity.compose.BackHandler
import androidx.activity.SystemBarStyle
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.animation.animateColorAsState
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.foundation.clickable
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.text.TextAutoSize
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.saveable.rememberSaveableStateHolder
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import org.json.JSONArray
import org.json.JSONObject
import java.text.DateFormat
import java.util.Date
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable fun RouteIcon(kind: String, description: String? = null, color: Color = MaterialTheme.colorScheme.onSurface) {
    Canvas(Modifier.size(24.dp).then(if (description == null) Modifier else Modifier.semantics { contentDescription = description })) {
        val stroke = Stroke(1.8f, cap = StrokeCap.Round)
        scale(size.width / 24, size.height / 24, Offset.Zero) {
            fun line(x: Float, y: Float, a: Float, b: Float) = drawLine(color, Offset(x, y), Offset(a, b), 1.8f, StrokeCap.Round)
            when (kind) {
                "home" -> { line(2f, 11f, 12f, 3f); line(12f, 3f, 22f, 11f); line(5f, 9f, 5f, 21f); line(5f, 21f, 19f, 21f); line(19f, 21f, 19f, 9f); line(10f, 21f, 10f, 15f); line(10f, 15f, 14f, 15f); line(14f, 15f, 14f, 21f) }
                "power" -> { drawArc(color, -45f, 270f, false, Offset(4f, 5f), Size(16f, 16f), style = stroke); line(12f, 2f, 12f, 12f) }
                "sources" -> { drawRoundRect(color, Offset(3f, 3f), Size(18f, 7f), androidx.compose.ui.geometry.CornerRadius(2f), style = stroke); drawRoundRect(color, Offset(3f, 14f), Size(18f, 7f), androidx.compose.ui.geometry.CornerRadius(2f), style = stroke); line(7f, 6.5f, 7.1f, 6.5f); line(7f, 17.5f, 7.1f, 17.5f) }
                "routing" -> { drawCircle(color, 2.4f, Offset(5f, 5f), style = stroke); drawCircle(color, 2.4f, Offset(19f, 5f), style = stroke); drawCircle(color, 2.4f, Offset(12f, 19f), style = stroke); line(5f, 8f, 5f, 12f); line(19f, 8f, 19f, 12f); line(5f, 12f, 19f, 12f); line(12f, 12f, 12f, 16f) }
                "settings" -> { line(3f, 6f, 21f, 6f); line(3f, 12f, 21f, 12f); line(3f, 18f, 21f, 18f); drawCircle(color, 2.5f, Offset(8f, 6f)); drawCircle(color, 2.5f, Offset(16f, 12f)); drawCircle(color, 2.5f, Offset(10f, 18f)) }
                "add" -> { line(12f, 4f, 12f, 20f); line(4f, 12f, 20f, 12f) }
                "expand" -> { line(6f, 9f, 12f, 15f); line(12f, 15f, 18f, 9f) }
                "unfold" -> { line(8f, 9.5f, 12f, 5.5f); line(12f, 5.5f, 16f, 9.5f); line(8f, 14.5f, 12f, 18.5f); line(12f, 18.5f, 16f, 14.5f) }
                "collapse" -> { line(6f, 15f, 12f, 9f); line(12f, 9f, 18f, 15f) }
                "back" -> { line(20f, 12f, 4f, 12f); line(4f, 12f, 11f, 5f); line(4f, 12f, 11f, 19f) }
                "more" -> { listOf(5f, 12f, 19f).forEach { drawCircle(color, 1.7f, Offset(12f, it)) } }
                "star" -> { val path = Path(); for (i in 0..9) { val a = Math.PI * (i / 5.0 - 0.5); val radius = if (i % 2 == 0) 10.0 else 4.5; val x = 12 + kotlin.math.cos(a) * radius; val y = 12 + kotlin.math.sin(a) * radius; if (i == 0) path.moveTo(x.toFloat(), y.toFloat()) else path.lineTo(x.toFloat(), y.toFloat()) }; path.close(); drawPath(path, color, style = stroke) }
                "check" -> { line(4f, 12f, 9f, 17f); line(9f, 17f, 20f, 6f) }
                "refresh" -> { drawArc(color, 35f, 290f, false, Offset(4f, 4f), Size(16f, 16f), style = stroke); line(20f, 3f, 20f, 9f); line(20f, 9f, 14f, 9f) }
                "search" -> { drawCircle(color, 6.5f, Offset(10f, 10f), style = stroke); line(15f, 15f, 21f, 21f) }
                "import" -> { line(12f, 2f, 12f, 14f); line(7f, 9f, 12f, 14f); line(12f, 14f, 17f, 9f); line(4f, 13f, 4f, 21f); line(4f, 21f, 20f, 21f); line(20f, 21f, 20f, 13f) }
                "ping" -> { line(2f, 12f, 7f, 12f); line(7f, 12f, 10f, 4f); line(10f, 4f, 14f, 20f); line(14f, 20f, 17f, 12f); line(17f, 12f, 22f, 12f) }
                "forward" -> { line(9f, 5f, 16f, 12f); line(16f, 12f, 9f, 19f) }
                "info" -> { drawCircle(color, 9f, Offset(12f, 12f), style = stroke); drawCircle(color, 1f, Offset(12f, 7f)); line(12f, 11f, 12f, 17f) }
                "lock" -> { drawRoundRect(color, Offset(5f, 10f), Size(14f, 11f), androidx.compose.ui.geometry.CornerRadius(2f), style = stroke); drawArc(color, 180f, 180f, false, Offset(8f, 2f), Size(8f, 14f), style = stroke); line(12f, 14f, 12f, 17f) }
                "dns" -> { drawCircle(color, 9f, Offset(12f, 12f), style = stroke); drawOval(color, Offset(8f, 3f), Size(8f, 18f), style = stroke); line(3f, 12f, 21f, 12f) }
                "appearance" -> { drawCircle(color, 9f, Offset(12f, 12f), style = stroke); drawArc(color, 90f, 180f, true, Offset(3f, 3f), Size(18f, 18f)) }
                "image" -> { drawRoundRect(color, Offset(3f, 3f), Size(18f, 18f), androidx.compose.ui.geometry.CornerRadius(2f), style = stroke); drawCircle(color, 2f, Offset(8f, 8f)); line(4f, 18f, 10f, 12f); line(10f, 12f, 14f, 16f); line(14f, 16f, 18f, 10f); line(18f, 10f, 21f, 13f) }
                "apps" -> { for (x in listOf(3f, 14f)) for (y in listOf(3f, 14f)) drawRoundRect(color, Offset(x, y), Size(7f, 7f), androidx.compose.ui.geometry.CornerRadius(1.5f), style = stroke) }
                "folder" -> { val path = Path(); path.moveTo(3f, 6f); path.lineTo(10f, 6f); path.lineTo(12f, 9f); path.lineTo(21f, 9f); path.lineTo(21f, 20f); path.lineTo(3f, 20f); path.close(); drawPath(path, color, style = stroke) }
                "shield" -> { val path = Path(); path.moveTo(12f, 3f); path.lineTo(21f, 7f); path.lineTo(19f, 16f); path.lineTo(12f, 21f); path.lineTo(5f, 16f); path.lineTo(3f, 7f); path.close(); drawPath(path, color, style = stroke); line(8f, 12f, 11f, 15f); line(11f, 15f, 16f, 9f) }
                "code" -> { line(8f, 7f, 3f, 12f); line(3f, 12f, 8f, 17f); line(16f, 7f, 21f, 12f); line(21f, 12f, 16f, 17f); line(14f, 5f, 10f, 19f) }
                "table" -> { drawRoundRect(color, Offset(3f, 4f), Size(18f, 16f), androidx.compose.ui.geometry.CornerRadius(2f), style = stroke); line(3f, 9.5f, 21f, 9.5f); line(3f, 14.5f, 21f, 14.5f); line(9.5f, 4f, 9.5f, 20f) }
                "pin" -> { line(8f, 3f, 16f, 3f); line(9f, 3f, 9f, 9f); line(15f, 3f, 15f, 9f); line(9f, 9f, 6f, 14f); line(15f, 9f, 18f, 14f); line(6f, 14f, 18f, 14f); line(12f, 14f, 12f, 22f) }
                else -> { line(6f, 6f, 18f, 18f); line(18f, 6f, 6f, 18f) }
            }
        }
    }
}

@Composable fun ElarniTheme(activity: MainActivity, settings: JSONObject, content: @Composable () -> Unit) {
    val dark = when (settings.string("theme", "system")) { "dark" -> true; "light" -> false; else -> isSystemInDarkTheme() }
    val accent = when (settings.string("accent", "evergreen")) { "evergreen" -> if (dark) Color(0xFF89A69A) else Color(0xFF284D42); "teal" -> if (dark) Color(0xFF68DBCB) else Color(0xFF006B60); "purple" -> if (dark) Color(0xFFD2BCFF) else Color(0xFF65429E); "orange" -> if (dark) Color(0xFFFFB685) else Color(0xFF944600); else -> if (dark) Color(0xFFA8C7FF) else Color(0xFF205BB5) }
    val surface = if (dark) Color(0xFF202124) else Color.White
    val foreground = if (dark) Color(0xFFF3F4F7) else Color(0xFF111827)
    val container = lerp(surface, accent, if (dark) 0.23f else 0.14f)
    val scheme = (if (dark) darkColorScheme() else lightColorScheme()).copy(
        primary = accent, onPrimary = if (dark) Color(0xFF10151D) else Color.White,
        primaryContainer = container, onPrimaryContainer = foreground,
        secondary = accent, onSecondary = if (dark) Color(0xFF10151D) else Color.White,
        secondaryContainer = container, onSecondaryContainer = foreground,
        tertiary = accent, tertiaryContainer = container, onTertiaryContainer = foreground,
        surface = surface, onSurface = foreground, background = surface, onBackground = foreground,
        surfaceDim = if (dark) Color(0xFF191A1D) else Color(0xFFE8EAF0),
        surfaceBright = if (dark) Color(0xFF3B3E45) else Color.White,
        surfaceContainerLowest = if (dark) Color(0xFF191A1D) else Color.White,
        surfaceVariant = if (dark) Color(0xFF34373E) else Color(0xFFE8EAF0),
        onSurfaceVariant = if (dark) Color(0xFFAEB3BF) else Color(0xFF626A7C),
        surfaceContainer = if (dark) Color(0xFF292B30) else Color(0xFFF1F2F5),
        surfaceContainerLow = if (dark) Color(0xFF25272C) else Color(0xFFF6F7F9),
        surfaceContainerHigh = if (dark) Color(0xFF303238) else Color(0xFFEFF0F4),
        surfaceContainerHighest = if (dark) Color(0xFF34373E) else Color(0xFFE8EAF0),
        surfaceTint = accent, outline = if (dark) Color(0xFF89909D) else Color(0xFF747B89),
        outlineVariant = if (dark) Color(0xFF3B3E45) else Color(0xFFDFE2E9),
    )
    SideEffect {
        // Follow the app's explicit theme even when Android uses the other one.
        val bars = SystemBarStyle.auto(android.graphics.Color.TRANSPARENT, android.graphics.Color.TRANSPARENT) { dark }
        activity.enableEdgeToEdge(statusBarStyle = bars, navigationBarStyle = bars)
    }
    MaterialTheme(colorScheme = scheme, content = content)
}

private data class Confirmation(val title: String, val text: String, val action: () -> Unit, val button: String = tr(R.string.delete))

// Counts taps on the current tab while it shows its own list.
private val LocalReselect = compositionLocalOf { 0 }
/** A tab's list state, which scrolls to the top when its tab is tapped again. */
@Composable private fun tabListState(): androidx.compose.foundation.lazy.LazyListState {
    val list = androidx.compose.foundation.lazy.rememberLazyListState()
    val reselect = LocalReselect.current
    // A list that appears after earlier taps starts where it was left.
    var handled by remember { mutableIntStateOf(reselect) }
    LaunchedEffect(reselect) { if (reselect != handled) { handled = reselect; list.animateScrollToItem(0) } }
    return list
}

@Composable private fun ImportMenu(activity: MainActivity, enabled: Boolean, description: String = tr(R.string.import_profiles), scan: () -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton({ open = true }, enabled = enabled, modifier = Modifier.heightIn(min = 48.dp).semantics { contentDescription = description }) {
            RouteIcon("import", color = MaterialTheme.colorScheme.primary); Spacer(Modifier.width(8.dp)); Text(tr(R.string.import_action))
        }
        DropdownMenu(open, { open = false }) {
            DropdownMenuItem({ Text(tr(R.string.import_from_clipboard)) }, { open = false; activity.paste() })
            DropdownMenuItem({ Text(tr(R.string.import_file)) }, { open = false; activity.pick("import") })
            DropdownMenuItem({ Text(tr(R.string.scan_qr_code)) }, { open = false; scan() })
        }
    }
}

@Composable private fun QRImportScreen(activity: MainActivity, busy: Boolean) {
    var allowed by remember { mutableStateOf(activity.cameraAllowed()) }
    var asked by rememberSaveable { mutableStateOf(false) }
    var unavailable by remember { mutableStateOf(false) }
    LifecycleResumeEffect(activity.cameraAnswers) { allowed = activity.cameraAllowed(); onPauseOrDispose {} }
    LaunchedEffect(Unit) { if (!allowed && !asked) { asked = true; activity.allowCamera() } }
    val hint = MaterialTheme.colorScheme.onSurfaceVariant
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        Text(tr(R.string.scan_a_connection_qr_code), style = MaterialTheme.typography.headlineSmall, textAlign = TextAlign.Center)
        if (allowed && !unavailable) {
            val portrait = LocalConfiguration.current.orientation != Configuration.ORIENTATION_LANDSCAPE
            LiveQRPreview(Modifier.widthIn(max = 420.dp).fillMaxWidth().aspectRatio(if (portrait) 3f / 4f else 4f / 3f).clip(RoundedCornerShape(16.dp))
                .semantics { contentDescription = tr(R.string.camera_preview) }, { activity.interaction.incoming = it }) { unavailable = true }
            Text(tr(R.string.hold_the_code_inside_the_frame), textAlign = TextAlign.Center, color = hint)
        } else {
            RouteIcon("image", color = hint)
            Text(if (allowed) tr(R.string.the_camera_could_not_start_photograph)
                else tr(R.string.allow_camera_access_to_read_the), textAlign = TextAlign.Center, color = hint)
            if (!allowed) Button({ activity.allowCamera() }, enabled = !busy) { Text(tr(R.string.allow_camera)) }
        }
        // Android refuses the camera app to an app whose camera permission is off.
        if (allowed) OutlinedButton({ activity.photographQR() }, enabled = !busy) { Text(tr(R.string.photograph_qr)) }
    }
}

@Composable private fun OnboardingStep(number: Int, text: String, actions: @Composable () -> Unit = {}) {
    Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        Box(Modifier.size(28.dp).background(MaterialTheme.colorScheme.secondaryContainer, RoundedCornerShape(50)), contentAlignment = Alignment.Center) {
            Text("$number", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.onSecondaryContainer)
        }
        Column(Modifier.weight(1f).padding(top = 3.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) { Text(text); actions() }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable fun ElarniUI(activity: MainActivity) {
    val state by activity.repository.state.collectAsStateWithLifecycle()
    val catalog = remember(state.catalog) { Catalog(state.catalog) }
    var page by rememberSaveable { mutableStateOf("home") }
    var detail by rememberSaveable { mutableStateOf("") }
    var id by rememberSaveable { mutableStateOf("") }
    var history by rememberSaveable { mutableStateOf(emptyList<String>()) }
    var tabs by rememberSaveable { mutableStateOf(emptyMap<String, String>()) }
    var reselect by remember { mutableIntStateOf(0) }
    val screenStates = rememberSaveableStateHolder()
    var confirmation by remember { mutableStateOf<Confirmation?>(null) }
    val snackbar = remember { SnackbarHostState() }
    fun navigate(destination: String, target: String = "") {
        if (destination.isEmpty()) history = emptyList()
        else history = history + obj("detail" to detail, "id" to id).toString()
        detail = destination; id = target
    }
    fun primary(destination: String) {
        if (destination == page) return
        tabs = tabs + (page to obj("detail" to detail, "id" to id, "history" to JSONArray(history)).toString())
        val saved = tabs[destination]?.let(::JSONObject)
        page = destination; detail = saved?.string("detail").orEmpty(); id = saved?.string("id").orEmpty(); history = saved?.strings("history") ?: emptyList()
    }
    fun back() {
        val prefixes = when (detail) {
            "settingsEditor" -> listOf("settings-$id")
            "route", "routeDNS", "routeJSON" -> listOf("routing-")
            "credentials" -> listOf("proxy-")
            "automation" -> listOf("automation-")
            "perApp" -> listOf("per-app-")
            "backup", "restore" -> listOf("backup-")
            "ping", "sourcePing" -> listOf("ping-body-")
            "sourceOptions" -> listOf("source-options-$id", "source-fallback-$id")
            else -> emptyList()
        }
        screenStates.removeState("$page/$detail/$id")
        activity.interaction.discardDrafts(prefixes)
        val previous = history.lastOrNull()?.let(::JSONObject)
        detail = previous?.string("detail").orEmpty(); id = previous?.string("id").orEmpty(); history = history.dropLast(1)
        activity.interaction.restore = null
    }
    // Tapping the current tab closes its open pages, then scrolls its list to the top.
    fun tab(destination: String) {
        if (destination != page) primary(destination)
        else if (detail.isNotEmpty()) while (detail.isNotEmpty()) back()
        else reselect++
    }
    LaunchedEffect(activity.interaction.dismissEditor) {
        if (activity.interaction.dismissEditor) { activity.interaction.dismissEditor = false; back() }
    }
    LaunchedEffect(activity.interaction.notice) {
        activity.interaction.notice?.let { notice ->
            snackbar.showSnackbar(notice, withDismissAction = true)
            if (activity.interaction.notice == notice) activity.interaction.notice = null
        }
    }
    LaunchedEffect(activity.interaction.incoming) {
        activity.interaction.incoming?.let { text ->
            activity.interaction.incoming = null
            if (detail == "scanQR") back()
            activity.run("import", obj("text" to text))
        }
    }
    // A rotation runs this again with the same file while its Restore screen is open.
    LaunchedEffect(activity.interaction.restore) { if (activity.interaction.restore != null && detail != "restore") navigate("restore") }
    LaunchedEffect(activity.interaction.importDestination) {
        activity.interaction.importDestination?.let { destination -> activity.interaction.importDestination = null; primary(destination) }
    }
    LaunchedEffect(state.event) {
        state.error?.let { error ->
            if (activity.interaction.lastErrorEvent != state.event) {
                activity.interaction.lastErrorEvent = state.event
                // A failed refresh names its provider and offers its support link.
                val source = state.errorSource?.let { id -> catalog.sources.firstOrNull { it.string("id") == id } }
                if (source == null) snackbar.showSnackbar(errorMessage(error), withDismissAction = true)
                else {
                    val support = source.mapObject("links").string("support").takeIf { error in providerFaults && it.isNotEmpty() }
                    val result = snackbar.showSnackbar(tr(R.string.the_last_working_servers_were_kept, refreshFailure(error, source.string("name"))), support?.let { tr(R.string.contact_provider) }, withDismissAction = true)
                    if (result == SnackbarResult.ActionPerformed && support != null) activity.openURL(support)
                }
            }
        }
    }
    BackHandler(detail.isNotEmpty() || page != "home") { if (detail.isNotEmpty()) back() else primary("home") }
    ElarniTheme(activity, catalog.settings) {
        Surface(Modifier.fillMaxSize()) {
            BoxWithConstraints {
                val expanded = maxWidth >= 600.dp
                val splitHome = maxWidth >= 840.dp || expanded && maxHeight < 480.dp
                val destinations = listOf("home" to tr(R.string.home), "sources" to tr(R.string.subscriptions), "routing" to tr(R.string.routing), "settings" to tr(R.string.settings))
                val title = when (detail) { "scanQR" -> tr(R.string.scan_qr_code); "backupSupport" -> tr(R.string.backup_and_repair); "source" -> catalog.sources.firstOrNull { it.string("id") == id }?.string("name") ?: tr(R.string.subscription); "node" -> tr(R.string.server_details); "route", "routeDNS" -> if (id.isEmpty()) tr(R.string.new_routing_profile) else tr(R.string.edit_routing); "routeJSON" -> tr(R.string.routing_json); "routeDetail" -> catalog.routes.firstOrNull { it.string("id") == id }?.string("name") ?: tr(R.string.routing); "shortcuts" -> tr(R.string.shortcuts); "perApp" -> tr(R.string.per_app_routing); "automation" -> tr(R.string.connection_recovery); "settingsEditor" -> Settings.sectionTitle(id); "credentials" -> tr(R.string.proxy_login); "backup" -> tr(R.string.export_encrypted_backup); "restore" -> tr(R.string.restore_backup); "ping" -> if (id.isEmpty()) tr(R.string.test_all_servers) else tr(R.string.test_this_server); "sourcePing" -> tr(R.string.test_subscription_servers); "sourceNodes" -> catalog.sources.firstOrNull { it.string("id") == id }?.string("name") ?: tr(R.string.subscription_servers); "sourceOptions" -> tr(R.string.download_options); "diagnostics" -> tr(R.string.troubleshooting); "logs" -> tr(R.string.logs); "systemInfo" -> tr(R.string.system_info); "routeTable" -> tr(R.string.route_table); "notices" -> tr(R.string.open_source_notices); else -> destinations.first { it.first == page }.second }
                Row(Modifier.fillMaxSize()) {
                    if (expanded) NavigationRail(Modifier.width(112.dp).fillMaxHeight().statusBarsPadding().verticalScroll(rememberScrollState()), containerColor = MaterialTheme.colorScheme.surfaceContainerLow) {
                        Image(painterResource(R.drawable.elarni_icon), null, Modifier.padding(16.dp).size(36.dp).clip(MaterialTheme.shapes.small))
                        destinations.forEach { (key, label) -> NavigationRailItem(page == key, { tab(key) }, { RouteIcon(key) }, label = { Text(label, textAlign = TextAlign.Center) }) }
                    }
                    Scaffold(Modifier.weight(1f),
                        topBar = { TopAppBar(title = { if (page == "home" && detail.isEmpty()) Image(painterResource(R.drawable.elarni_icon), "Elarni", Modifier.size(36.dp).clip(MaterialTheme.shapes.small)) else Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) },
                            navigationIcon = { if (detail.isNotEmpty()) IconButton({ back() }) { RouteIcon("back", tr(R.string.back)) } },
                            colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.surface),
                            actions = {
                                if (detail.isEmpty() && page == "home") ImportMenu(activity, !state.loading && !state.busy) { navigate("scanQR") }
                                if (detail.isEmpty() && page == "routing") TextButton({ navigate("route", "") }, enabled = !state.loading && !state.busy, modifier = Modifier.heightIn(min = 48.dp)) { RouteIcon("add", color = MaterialTheme.colorScheme.primary); Spacer(Modifier.width(8.dp)); Text(tr(R.string.new_profile)) }
                                if (detail == "scanQR") IconButton({ activity.pick("qr") }, enabled = !state.busy) { RouteIcon("image", tr(R.string.choose_qr_image), MaterialTheme.colorScheme.primary) }
                            }) },
                        bottomBar = { if (!expanded && detail != "scanQR") NavigationBar(containerColor = MaterialTheme.colorScheme.surfaceContainerLow, tonalElevation = 0.dp) {
                            destinations.forEach { (key, label) -> NavigationBarItem(page == key, { tab(key) }, { RouteIcon(key) }, label = {
                                // One line each; only a label that doesn't fit shrinks.
                                Text(label, textAlign = TextAlign.Center, maxLines = 1, softWrap = false,
                                    autoSize = TextAutoSize.StepBased(minFontSize = 9.sp, maxFontSize = LocalTextStyle.current.fontSize, stepSize = 0.5.sp))
                            }) }
                        } },
                        snackbarHost = { SnackbarHost(snackbar) }) { padding ->
                        Box(Modifier.fillMaxSize().padding(padding).imePadding()) {
                            Box(Modifier.widthIn(max = if (page == "home" && detail.isEmpty()) androidx.compose.ui.unit.Dp.Infinity else 760.dp).fillMaxSize().align(Alignment.TopCenter)) {
                            if (state.loading) Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) { CircularProgressIndicator(); Text(tr(R.string.opening_your_catalog), Modifier.padding(16.dp)) }
                            else screenStates.SaveableStateProvider("$page/$detail/$id") { when (detail) {
                                "scanQR" -> QRImportScreen(activity, state.busy)
                                "source" -> SourceScreen(catalog, id, activity, state.busy, state.pings, ::navigate) { titleText, text, button, action -> confirmation = Confirmation(titleText, text, action, button) }
                                "node" -> NodeScreen(catalog, id, activity, state, ::navigate, ::back) { titleText, text, button, action -> confirmation = Confirmation(titleText, text, action, button) }
                                "route" -> RoutingEditor(catalog.routes.firstOrNull { it.string("id") == id }, state.busy, activity) { back() }
                                "routeDNS" -> RoutingEditor(catalog.routes.firstOrNull { it.string("id") == id }, state.busy, activity, initialSection = "dns") { back() }
                                "routeJSON" -> RoutingEditor(catalog.routes.firstOrNull { it.string("id") == id }, state.busy, activity, initialSection = "json") { back() }
                                "routeDetail" -> RoutingDetailScreen(catalog, id, state.busy, activity, ::navigate) { titleText, text, action -> confirmation = Confirmation(titleText, text, action) }
                                "perApp" -> PerAppEditor(catalog.settings, catalog.nodes.filter { it.string("format") == "xrayProfile" }.map { it.string("id") to it.string("name") }, state.busy, activity) { back() }
                                "automation" -> AutomationEditor(catalog, state.busy, activity) { back() }
                                "settingsEditor" -> SettingsEditor(catalog, id, state.busy, activity, ::navigate, { primary("home") }) { back() }
                                "credentials" -> CredentialsEditor(state.busy, activity) { back() }
                                "backup", "restore" -> BackupEditor(detail == "restore", state.busy, activity) { back() }
                                "ping" -> PingEditor(id, state, activity)
                                "sourcePing" -> PingEditor("", state, activity, sourceId = id)
                                "sourceNodes" -> HomeScreen(catalog, state, false, activity, ::navigate, sourceId = id)
                                "sourceOptions" -> SourceOptionsEditor(catalog, id, state.busy, activity) { back() }
                                "diagnostics", "systemInfo", "routeTable" -> DiagnosticsScreen(detail, state, activity, ::navigate)
                                "logs" -> LogsScreen(catalog, state.busy, activity)
                                "notices" -> NoticesScreen(activity)
                                "backupSupport" -> BackupSupportScreen(state, activity, ::navigate)
                                "shortcuts" -> SettingsColumn {
                                    SettingsGroup {
                                        listOf("connect", "disconnect", "toggle", "status").forEach { action -> SettingsTile(tr(R.string.copy_link, action), "elarni://$action") { activity.copy("elarni://$action") } }
                                    }
                                    SettingsGroup(tr(R.string.automation_apps), tr(R.string.with_let_other_apps_control_the, activity.packageName) +
                                        tr(R.string.receiver_com_elarni_remotecontrol_with_the) +
                                        tr(R.string.connecting_needs_a_chosen_server_and)) {}
                                }
                                else -> CompositionLocalProvider(LocalReselect provides reselect) { when (page) {
                                    "home" -> HomeScreen(catalog, state, splitHome, activity, ::navigate)
                                    "sources" -> SourcesScreen(catalog, state.busy, activity, ::navigate)
                                    "routing" -> RoutingScreen(catalog, state.busy, activity, ::navigate)
                                    "settings" -> SettingsScreen(catalog, activity, ::navigate)
                                } }
                            } }
                            }
                            if (state.busy) Row(Modifier.align(Alignment.BottomCenter).fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                                LinearProgressIndicator(Modifier.weight(1f)); TextButton({ activity.repository.cancel() }) { Text(tr(R.string.cancel)) }
                            }
                        }
                    }
                }
            }
        }
        confirmation?.let { value -> AlertDialog(onDismissRequest = { confirmation = null }, title = { Text(value.title) }, text = { Text(value.text) },
            confirmButton = { TextButton({ confirmation = null; value.action() }) { Text(value.button) } }, dismissButton = { TextButton({ confirmation = null }) { Text(tr(R.string.cancel)) } }) }
        activity.interaction.linkImport?.let { link -> AlertDialog(onDismissRequest = { activity.interaction.linkImport = null }, title = { Text(tr(R.string.import_this_link)) }, text = { Text(tr(R.string.a_link_wants_to_add_profiles)) },
            confirmButton = { TextButton({ activity.interaction.linkImport = null; activity.interaction.incoming = link }) { Text(tr(R.string.import_action)) } }, dismissButton = { TextButton({ activity.interaction.linkImport = null }) { Text(tr(R.string.cancel)) } }) }
        if (activity.interaction.linkStop) AlertDialog(onDismissRequest = { activity.interaction.linkStop = false }, title = { Text(tr(R.string.disconnect_elarni)) }, text = { Text(tr(R.string.a_link_asks_elarni_to_disconnect)) },
            confirmButton = { TextButton({ activity.interaction.linkStop = false; activity.repository.requestStop() }) { Text(tr(R.string.disconnect)) } }, dismissButton = { TextButton({ activity.interaction.linkStop = false }) { Text(tr(R.string.cancel)) } })
        state.approval?.let { warning -> AlertDialog(onDismissRequest = { activity.run("reject") }, title = { Text(tr(R.string.review_download_destination)) },
            text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text(tr(R.string.this_download_needs_your_approval_before))
                warning.strings("chain").forEach { value -> Text(runCatching { val uri = java.net.URI(value); "${uri.scheme}://${uri.host}${if (uri.port == -1) "" else ":${uri.port}"}" }.getOrDefault(tr(R.string.invalid_destination))) }
                warning.strings("riskCodes").forEach { Text(it.replace('_', ' ')) }
            } }, confirmButton = { TextButton({ activity.run(if (warning.string("mode") == "resource") "approveResource" else "approveSource", obj("token" to warning.getString("token"))) }, enabled = !state.busy) { Text(tr(R.string.approve_destination)) } },
            dismissButton = { TextButton({ activity.run("reject") }, enabled = !state.busy) { Text(tr(R.string.cancel)) } }) }
        activity.interaction.share?.let { result -> ShareDialog(result, activity) { activity.interaction.share = null } }
    }
}

// Compact, so the server list starts on the first screen; Troubleshooting and recovery live in Settings.
@Composable private fun ConnectionPanel(catalog: Catalog, state: AppState, activity: MainActivity, scrollServers: () -> Unit) {
    val active = state.connection in listOf("connected", "connecting", "paused", "disconnecting")
    val selected = catalog.nodes.firstOrNull { it.string("id") == catalog.selected }
    Column(Modifier.fillMaxWidth().padding(start = 24.dp, end = 24.dp, top = 8.dp, bottom = 12.dp), verticalArrangement = Arrangement.spacedBy(8.dp), horizontalAlignment = Alignment.CenterHorizontally) {
        val prefs = remember { activity.getSharedPreferences("ui", android.content.Context.MODE_PRIVATE) }
        var loginNoticeHidden by remember { mutableStateOf(prefs.getBoolean("loginWarningDismissed", false)) }
        // With System VPN on, the proxy always needs a login; only local proxy mode can be open.
        if (!catalog.settings.optBoolean("xrayTunEnabled") && !catalog.settings.optBoolean("inboundAuthEnabled") && !loginNoticeHidden)
            HomeNotice(tr(R.string.your_local_proxy_accepts_apps_without), tr(R.string.any_app_on_this_device_can),
                tr(R.string.require_a_login) to { activity.run("settings", obj("settings" to obj("inboundAuthEnabled" to true))) },
                tr(R.string.not_now) to { loginNoticeHidden = true; prefs.edit().putBoolean("loginWarningDismissed", true).apply() })
        val feed = catalog.settings.string("updateFeedURL")
        // Each minute asks whether the day (or, while the feed is unreadable, the hour) has passed.
        LaunchedEffect(feed) { do { UpdateCheck.refresh(feed); delay(60_000) } while (feed.isNotEmpty()) }
        val update by UpdateCheck.available.collectAsStateWithLifecycle()
        var dismissedUpdate by remember { mutableStateOf(prefs.getString("dismissedUpdate", "") ?: "") }
        update?.takeIf { it.first != dismissedUpdate }?.let { (version, url) ->
            HomeNotice(tr(R.string.elarni_is_available, version), tr(R.string.you_have_it_keeps_working_update, BuildConfig.VERSION_NAME),
                tr(R.string.download) to { activity.openURL(url) },
                tr(R.string.not_now) to { dismissedUpdate = version; prefs.edit().putString("dismissedUpdate", version).apply() })
        }
        val noTraffic = state.connection == "connected" && state.liveness == "noTraffic"
        val warning = if (MaterialTheme.colorScheme.surface == Color(0xFF202124)) Color(0xFFFDE047) else Color(0xFF854D0E)
        ConnectionArtwork(state.connection == "connected", state.connection == "failed", if (noTraffic) warning else null)
        Text(when (state.connection) { "connected" -> if (noTraffic) tr(R.string.connected_no_traffic) else tr(R.string.connected); "connecting" -> tr(R.string.connecting); "paused" -> tr(R.string.paused); "failed" -> tr(R.string.connection_failed); "disconnecting" -> tr(R.string.disconnecting); else -> tr(R.string.disconnected) }, style = MaterialTheme.typography.titleMedium, textAlign = TextAlign.Center,
            // TalkBack hears each change; the artwork above stays decorative, as on iPhone and desktop.
            color = if (noTraffic) warning else Color.Unspecified, modifier = Modifier.semantics { liveRegion = LiveRegionMode.Polite })
        if (noTraffic) state.noTrafficSince?.let { since ->
            val time = android.text.format.DateFormat.getTimeFormat(LocalContext.current).format(java.util.Date(since))
            Text(tr(R.string.the_server_passed_no_traffic_at, time), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        }
        Text(selected?.string("name") ?: tr(R.string.no_server_selected), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center, modifier = Modifier.heightIn(min = 48.dp).clickable(enabled = selected != null, onClick = scrollServers).wrapContentHeight(), color = if (selected != null) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
        Button(onClick = { if (active) activity.repository.requestStop() else if (state.busy) activity.repository.cancel() else activity.connect() }, enabled = active || state.busy || selected != null,
            modifier = Modifier.widthIn(max = 320.dp).fillMaxWidth().heightIn(min = 48.dp)) { Text(if (active) { if (state.connection == "connected") tr(R.string.disconnect) else tr(R.string.stop) } else if (state.busy) tr(R.string.stop) else tr(R.string.connect), style = MaterialTheme.typography.titleMedium) }
        if (!catalog.settings.optBoolean("xrayTunEnabled")) Text("SOCKS 127.0.0.1:${catalog.settings.optInt("socksPort")}", style = MaterialTheme.typography.bodySmall)
        if (catalog.settings.optBoolean("monitoringEnabled") && state.connection == "connected") {
            val metrics = state.metrics
            Text(tr(R.string.sent_received, bytes(metrics.optLong("uplinkBytes")), bytes(metrics.optLong("downlinkBytes"))), style = MaterialTheme.typography.bodyMedium)
            Text(tr(R.string.tcp_udp_memory, metrics.optInt("activeTcpSessions"), metrics.optInt("activeUdpSessions"), bytes(metrics.optLong("heapAllocBytes"))), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (BuildConfig.ELARNI_RECORDING && catalog.settings.optBoolean("recordDiagnostics")) TextButton({ activity.markRecording() }, Modifier.heightIn(min = 48.dp)) { Text(tr(R.string.mark_a_problem_now)) }
    }
}

// An amber notice above the connection control, as on desktop Home.
@Composable private fun HomeNotice(title: String, body: String, vararg actions: Pair<String, () -> Unit>) {
    val dark = MaterialTheme.colorScheme.surface == Color(0xFF202124)
    val ink = if (dark) Color(0xFFFDE047) else Color(0xFF854D0E)
    Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(16.dp)).background(if (dark) Color(0xFF453810) else Color(0xFFFEF9C3))
        .semantics { liveRegion = LiveRegionMode.Polite }.padding(start = 16.dp, end = 8.dp, top = 12.dp)) {
        Text(title, Modifier.padding(end = 8.dp), style = MaterialTheme.typography.titleSmall, color = ink)
        Text(body, Modifier.padding(end = 8.dp), style = MaterialTheme.typography.bodyMedium, color = ink)
        Row(Modifier.align(Alignment.End)) { actions.forEach { (label, action) -> TextButton(action, colors = ButtonDefaults.textButtonColors(contentColor = ink)) { Text(label) } } }
    }
}

// A warning tint replaces the green: connected, but the server passes no traffic.
@Composable private fun ConnectionArtwork(connected: Boolean, failed: Boolean, warning: Color? = null) {
    val reveal by animateFloatAsState(if (connected && !failed && warning == null) 1f else 0f, tween(400, easing = LinearEasing), label = "Connection reveal")
    // iOS fades the whole symbol to 70%; an opaque blend keeps the hub and mast from darkening where they overlap.
    val ink by animateColorAsState(if (failed) MaterialTheme.colorScheme.error else warning ?: lerp(MaterialTheme.colorScheme.surface, MaterialTheme.colorScheme.onSurfaceVariant, 0.7f), tween(400, easing = LinearEasing), label = "Connection failure")
    val success = Color(0xFF24B83E)
    val scale = LocalDensity.current.fontScale.coerceIn(1f, 1.35f)
    Canvas(Modifier.size(74.dp * scale, 64.dp * scale)) {
        // The iPhone's antenna.radiowaves.left.and.right at 61 pt, measured in units of its outer wave radius.
        val unit = size.width / 2.53f
        val hub = Offset(size.width / 2, unit * 0.87f)
        fun antenna(color: Color) {
            val stroke = Stroke(unit * 0.16f, cap = StrokeCap.Round)
            drawLine(color, hub, Offset(hub.x, hub.y + unit * 1.1f), stroke.width, StrokeCap.Round)
            drawCircle(color, unit * 0.178f, hub)
            listOf(1f to 40f, 0.57f to 36f).forEach { (radius, sweep) ->
                val origin = Offset(hub.x - unit * radius, hub.y - unit * radius)
                val bounds = Size(unit * radius * 2, unit * radius * 2)
                drawArc(color, 180f - sweep, sweep * 2, false, origin, bounds, style = stroke)
                drawArc(color, -sweep, sweep * 2, false, origin, bounds, style = stroke)
            }
        }
        antenna(ink)
        val radius = kotlin.math.hypot(size.width, size.height) / 2
        if (!failed && reveal > 0f) clipPath(Path().apply { addOval(androidx.compose.ui.geometry.Rect(center, radius * reveal)) }) { antenna(success) }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun HomeScreen(catalog: Catalog, state: AppState, expanded: Boolean, activity: MainActivity, navigate: (String, String) -> Unit, sourceId: String = "") {
    val tick by rememberClock()
    // A newly completed measurement must not be compared with the previous
    // 30-second timer tick (which would label it as a future/outdated result).
    val clock = remember(tick, state.pings) { now() }
    val locations = remember { ServerLocations(activity) }
    val locationByName = remember(catalog.nodes.map { it.string("name") }) { catalog.nodes.map { it.string("name") }.distinct().associateWith(locations::fromName) }
    var search by rememberSaveable { mutableStateOf("") }
    var filter by rememberSaveable { mutableStateOf("all") }
    val expandedGroups = rememberSaveable(saver = androidx.compose.runtime.saveable.mapSaver(
        save = { it.toMap() }, restore = { saved -> mutableStateMapOf<String, Boolean>().apply { saved.forEach { (key, value) -> put(key, value as Boolean) } } }
    )) { mutableStateMapOf<String, Boolean>() }
    var country by rememberSaveable { mutableStateOf("") }
    var options by remember { mutableStateOf(false) }
    val sort = catalog.settings.string("sort")
    val favoritesFirst = catalog.settings.optBoolean("favoritesFirst", true)
    // Clock ticks and test progress recompose Home often; its list changes only with these.
    val (sources, countries, rows, groups) = remember(catalog, sourceId, search, country, filter, if (sort == "latency") state.pings to clock else null) {
    val sources = catalog.sources.filter { sourceId.isEmpty() || it.string("id") == sourceId }
    val countries = sources.flatMap { it.objects("nodes") }.mapNotNull { locationByName[it.string("name")] }.distinct().sortedBy { it.name }
                var rows = sources.sortedByDescending { it.optBoolean("pinned") }.flatMap { source -> source.objects("nodes").map { source to it } }
                    .filter { (source, node) ->
                        val location = locationByName[node.string("name")]
                        val outbound = node.mapObject("config").objects("outbounds").firstOrNull { it.string("protocol") !in listOf("freedom", "blackhole", "dns") }
                        val stream = outbound?.mapObject("streamSettings")
                        val matches = listOf(source.string("name"), node.string("name"), location?.name.orEmpty(), outbound?.string("protocol").orEmpty(), if (outbound?.string("protocol") == "tuic") "QUIC" else stream?.string("network").orEmpty(), stream?.string("security").orEmpty()).any { it.contains(search, true) }
                        matches && (country.isEmpty() || country == (location?.code ?: "other")) && when (filter) { "favorites" -> node.optBoolean("favorite"); "recent" -> node.optDouble("lastSuccessAt", 0.0) > 0; else -> true }
                    }
                rows = if (filter == "recent") rows.sortedWith(compareBy<Pair<JSONObject, JSONObject>> { !it.first.optBoolean("pinned") }.thenByDescending { it.second.optDouble("lastSuccessAt", 0.0) })
                else when (sort) {
                    "alphabet" -> rows.sortedWith(compareBy<Pair<JSONObject, JSONObject>> { !it.first.optBoolean("pinned") }.thenBy { it.second.string("name").lowercase() })
                    "latency" -> rows.sortedWith(compareBy<Pair<JSONObject, JSONObject>> { !it.first.optBoolean("pinned") }.thenBy { (_, node) -> state.pings[node.string("id")]?.takeIf { pingFresh(node, it, clock) && it.string("status") == "success" }?.optLong("latencyMs", Long.MAX_VALUE) ?: Long.MAX_VALUE })
                    else -> rows
                }.let { sorted ->
                    // Stable, so the order chosen above holds among favorites and among the rest.
                    if (favoritesFirst) sorted.sortedWith(compareBy<Pair<JSONObject, JSONObject>> { !it.first.optBoolean("pinned") }.thenBy { !it.second.optBoolean("favorite") }) else sorted
                }
    val grouped = rows.groupBy { locationByName[it.second.string("name")] }
    HomeList(sources, countries, rows, grouped.keys.sortedWith(compareBy<ServerLocation?> { it == null }.thenBy { it?.name.orEmpty() }).map { it to grouped.getValue(it) })
    }
    val eligibleIds = rows.map { it.second }.filter { it.string("format") == "xrayProfile" }.map { it.string("id") }
    val listState = tabListState()
    val scope = rememberCoroutineScope()
    val scrollServers: () -> Unit = { scope.launch { listState.animateScrollToItem(if (!expanded && sourceId.isEmpty()) 1 else 0) } }
    // Only a pull shows the indicator; connecting or testing keeps their own progress bar.
    var refreshing by remember { mutableStateOf(false) }
    val refreshable = sources.filter { it.has("url") }.map { it.string("id") }
    PullToRefreshBox(isRefreshing = refreshing, onRefresh = {
        if (!state.busy && refreshable.isNotEmpty()) scope.launch { refreshing = true; try { activity.refreshAll(refreshable).join() } finally { refreshing = false } }
    }) {
    Row(Modifier.fillMaxSize()) {
        if (expanded) Box(Modifier.widthIn(max = 360.dp).weight(0.38f).verticalScroll(rememberScrollState())) { ConnectionPanel(catalog, state, activity, scrollServers) }
        LazyColumn(Modifier.weight(if (expanded) 0.62f else 1f), state = listState, contentPadding = PaddingValues(bottom = 24.dp)) {
            if (!expanded && sourceId.isEmpty()) item { ConnectionPanel(catalog, state, activity, scrollServers) }
            if (sourceId.isNotEmpty()) item { TextButton({ navigate("sourcePing", sourceId) }, Modifier.padding(horizontal = 24.dp), enabled = !state.busy) { Text(tr(R.string.test_subscription_servers)) } }
            // Elarni ships no servers, so a new install starts with where one comes from.
            if (catalog.nodes.isEmpty()) item {
                Column(Modifier.padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                    Text(tr(R.string.get_connected_in_three_steps), Modifier.semantics { heading() }, style = MaterialTheme.typography.titleLarge)
                    OnboardingStep(1, tr(R.string.get_a_subscription_link_or_qr))
                    OnboardingStep(2, tr(R.string.add_it_here)) {
                        FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton({ activity.paste() }, enabled = !state.busy) { Text(tr(R.string.paste_link)) }
                            OutlinedButton({ navigate("scanQR", "") }, enabled = !state.busy) { Text(tr(R.string.scan_qr_code)) }
                            OutlinedButton({ activity.pick("import") }, enabled = !state.busy) { Text(tr(R.string.open_file)) }
                        }
                    }
                    OnboardingStep(3, if (catalog.settings.optBoolean("xrayTunEnabled", true)) tr(R.string.press_connect_android_asks_once_to)
                        else tr(R.string.press_connect_only_apps_set_to))
                }
            } else {
                item { Column(Modifier.padding(horizontal = 16.dp).padding(bottom = 4.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    val filters = listOf("all" to tr(R.string.all), "favorites" to tr(R.string.favorites), "recent" to tr(R.string.recent))
                    // The filters take the place of a "Servers" title, which screen readers still hear.
                    Row(Modifier.semantics { heading(); contentDescription = tr(R.string.servers) }, verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        if (LocalDensity.current.fontScale > 1.2f) FlowRow(Modifier.weight(1f), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            filters.forEach { (key, title) -> FilterChip(filter == key, { filter = key }, label = { Text(title) }) }
                        } else SingleChoiceSegmentedButtonRow(Modifier.weight(1f)) {
                            filters.forEachIndexed { index, (key, title) -> SegmentedButton(filter == key, { filter = key }, shape = SegmentedButtonDefaults.itemShape(index, filters.size), label = { Text(title, maxLines = 1, softWrap = false) }) }
                        }
                        Box {
                            IconButton({ options = true }) { RouteIcon("settings", tr(R.string.server_options), MaterialTheme.colorScheme.primary) }
                            DropdownMenu(options, { options = false }) {
                                Text(tr(R.string.country), Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.labelLarge)
                                DropdownMenuItem({ Text(tr(R.string.all_locations)) }, { country = ""; options = false }, trailingIcon = { if (country.isEmpty()) RouteIcon("check") })
                                countries.forEach { location -> DropdownMenuItem({ Text(location.name) }, { country = location.code; options = false }, trailingIcon = { if (country == location.code) RouteIcon("check") }) }
                                if (sources.flatMap { it.objects("nodes") }.any { locationByName[it.string("name")] == null }) DropdownMenuItem({ Text(tr(R.string.other_locations)) }, { country = "other"; options = false })
                                HorizontalDivider()
                                Text(tr(R.string.sort), Modifier.padding(horizontal = 16.dp, vertical = 8.dp), style = MaterialTheme.typography.labelLarge)
                                listOf("provider" to tr(R.string.provider_order), "alphabet" to tr(R.string.alphabetical), "latency" to tr(R.string.lowest_latency)).forEach { (value, label) ->
                                    DropdownMenuItem({ Text(label) }, { options = false; activity.run("settings", obj("settings" to obj("sort" to value))) }, trailingIcon = { if (catalog.settings.string("sort") == value) RouteIcon("check") })
                                }
                                HorizontalDivider()
                                DropdownMenuItem({ Text(tr(R.string.favorites_first)) }, { options = false; activity.run("settings", obj("settings" to obj("favoritesFirst" to !favoritesFirst))) }, trailingIcon = { if (favoritesFirst) RouteIcon("check") })
                            }
                        }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextField(search, { search = it }, label = { Text(tr(R.string.search_servers)) }, leadingIcon = { RouteIcon("search", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                            singleLine = true, shape = MaterialTheme.shapes.medium,
                            trailingIcon = if (search.isEmpty()) null else {{ IconButton({ search = "" }) { RouteIcon("clear", tr(R.string.clear_search)) } }},
                            colors = TextFieldDefaults.colors(focusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow, unfocusedContainerColor = MaterialTheme.colorScheme.surfaceContainerLow), modifier = Modifier.weight(1f))
                        IconButton({ activity.testServers(eligibleIds, sourceId) }, enabled = !state.busy && eligibleIds.isNotEmpty()) { RouteIcon("ping", tr(R.string.test_visible_servers), MaterialTheme.colorScheme.primary) }
                    }
                    if (country.isNotEmpty()) Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(countries.firstOrNull { it.code == country }?.name ?: tr(R.string.other_locations), Modifier.weight(1f), color = MaterialTheme.colorScheme.onSurfaceVariant)
                        TextButton({ country = "" }) { Text(tr(R.string.all_locations)) }
                    }
                } }
                groups.forEach { (location, entries) ->
                    val code = location?.code ?: "other"
                    val open = search.isNotBlank() || filter != "all" || (expandedGroups[code] ?: (location == null || entries.any { it.second.string("id") == catalog.selected }))
                    val best = entries.mapNotNull { (_, node) -> state.pings[node.string("id")]?.takeIf { pingFresh(node, it, clock) && it.string("status") == "success" && it.optLong("latencyMs", -1) >= 0 }?.getLong("latencyMs") }.minOrNull()
                    // A country and its servers are one rounded group, as in Settings, so each header starts a visible block.
                    val count = if (open) entries.size + 1 else 1
                    // The gaps sit outside each ListItem so its bounds, and TalkBack's outline, are the visible tile.
                    item(key = "country-$code") { Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 12.dp)) {
                        ListItem(headlineContent = { Row(horizontalArrangement = Arrangement.spacedBy(8.dp), verticalAlignment = Alignment.CenterVertically) {
                                Text(location?.name ?: tr(R.string.other_locations), Modifier.weight(1f, fill = false), style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
                                Text("· " + trPlural(R.plurals.server_count, entries.size), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, maxLines = 1)
                                if (best != null) LatencyBadge(best, Modifier.testTag("country-ping-$code"), trPlural(R.plurals.lowest_latency_ms, best.toInt()))
                            } },
                            leadingContent = {
                                val flag = location?.let { locations.flagImage(it.code) }
                                // A hairline keeps dark flag edges visible on the dark tile.
                                if (flag != null) Image(flag, null, Modifier.size(28.dp, 21.dp).clip(MaterialTheme.shapes.extraSmall)
                                    .border(0.5.dp, MaterialTheme.colorScheme.onSurface.copy(alpha = 0.16f), MaterialTheme.shapes.extraSmall))
                                else RouteIcon("dns")
                            },
                            trailingContent = { RouteIcon(if (open) "collapse" else "expand") },
                            colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
                            modifier = Modifier.clip(segmentShape(0, count)).clickable { expandedGroups[code] = !open })
                    } }
                    if (open) itemsIndexed(entries, key = { _, entry -> entry.second.string("id") }) { index, (source, node) ->
                        val selected = node.string("id") == catalog.selected
                        val ping = state.pings[node.string("id")]
                        var menu by remember { mutableStateOf(false) }
                        val exit = state.exits[node.string("id")]
                        Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 2.dp)) {
                        ListItem(headlineContent = { Text(locations.displayName(node.string("name")), fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal) },
                            supportingContent = { if (exit == null) ServerProtocol(node, source.string("name")) else Column { ServerProtocol(node, source.string("name")); ExitLine(node, exit, locations) } },
                            // As on the iPhone, only a current test result shows, beside the menu.
                            leadingContent = { RadioButton(selected, null) }, trailingContent = { Row(verticalAlignment = Alignment.CenterVertically) {
                                if (ping != null && pingFresh(node, ping, clock)) {
                                    if (ping.string("status") == "success" && ping.optLong("latencyMs", -1) >= 0)
                                        LatencyBadge(ping.getLong("latencyMs"), Modifier.testTag("server-ping-${node.string("id")}"), trPlural(R.plurals.latency_with_scope, ping.getLong("latencyMs").toInt(), ping.getLong("latencyMs"), pingScope(ping)))
                                    else Text(tr(R.string.failed), Modifier.semantics { contentDescription = tr(R.string.test_failed, pingScope(ping)) }, style = MaterialTheme.typography.labelMedium, color = MaterialTheme.colorScheme.error)
                                }
                                if (node.optBoolean("favorite")) RouteIcon("star", tr(R.string.favorite), MaterialTheme.colorScheme.primary)
                                Box {
                                    IconButton({ menu = true }) { RouteIcon("more", tr(R.string.server_actions)) }
                                    DropdownMenu(menu, { menu = false }) {
                                        DropdownMenuItem({ Text(tr(R.string.details)) }, { menu = false; navigate("node", node.string("id")) })
                                        DropdownMenuItem({ Text(if (node.optBoolean("favorite")) tr(R.string.remove_favorite) else tr(R.string.favorite)) }, { menu = false; activity.run("favorite", obj("id" to node.string("id"), "value" to !node.optBoolean("favorite"))) }, enabled = !state.busy)
                                        if (node.string("format") != "telegram") DropdownMenuItem({ Text(tr(R.string.test_server)) }, { menu = false; activity.testServers(listOf(node.string("id"))) }, enabled = !state.busy)
                                        if (node.string("format") != "telegram") DropdownMenuItem({ Text(tr(R.string.check_exit)) }, { menu = false; activity.checkExit(node.string("id")) }, enabled = !state.busy)
                                        DropdownMenuItem({ Text(tr(R.string.share)) }, { menu = false; activity.run("share", obj("id" to node.string("id"))) { activity.interaction.share = it } }, enabled = !state.busy)
                                    }
                                }
                            } },
                            colors = ListItemDefaults.colors(containerColor = if (selected) MaterialTheme.colorScheme.secondaryContainer else MaterialTheme.colorScheme.surfaceContainerHigh),
                            modifier = Modifier.clip(segmentShape(index + 1, count)).semantics { this.selected = selected }.clickable(enabled = !state.busy) { if (node.string("format") == "telegram") activity.openURL(node.mapObject("config").string("url"), true) else activity.run("select", obj("id" to node.string("id"))) })
                        }
                    }
                }
                if (rows.isEmpty()) item { Text(tr(R.string.no_servers_match_this_filter), Modifier.padding(24.dp), color = MaterialTheme.colorScheme.onSurfaceVariant) }
                item { Row(Modifier.fillMaxWidth().padding(24.dp)) {
                    Text(if (search.isNotEmpty()) tr(R.string.search_results) else when (filter) { "favorites" -> tr(R.string.favorites); "recent" -> tr(R.string.recent_servers); else -> tr(R.string.all_servers) }, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(trPlural(R.plurals.server_count, rows.size), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                } }
            }
        }
    }
    }
}

private data class HomeList(val sources: List<JSONObject>, val countries: List<ServerLocation>, val rows: List<Pair<JSONObject, JSONObject>>,
    val groups: List<Pair<ServerLocation?, List<Pair<JSONObject, JSONObject>>>>)

// A provider's name is a label and the trace is evidence, so a disagreement is said.
@Composable private fun ExitLine(node: JSONObject, exit: JSONObject, locations: ServerLocations) {
    val muted = MaterialTheme.colorScheme.onSurfaceVariant
    when (exit.string("status")) {
        "pending" -> Text(tr(R.string.checking_exit), style = MaterialTheme.typography.bodySmall, color = muted)
        "success" -> {
            if (exit.string("configurationRevision") != node.string("configurationRevision", node.string("id"))) return
            val code = exit.mapObject("exit").string("country")
            val actual = locations.fromCode(code)
            val country = when (code) { "XX" -> tr(R.string.unknown_country); "T1" -> "Tor"; else -> actual?.name ?: code }
            Text(tr(R.string.exit, country, exit.mapObject("exit").string("ip")), style = MaterialTheme.typography.bodySmall, color = muted)
            val named = locations.fromName(node.string("name"))
            if (named != null && named.code != "EU" && actual != null && actual.code != named.code)
                Text(tr(R.string.s_name_says_but_its_exit, locations.displayName(node.string("name")), named.name, actual.name), style = MaterialTheme.typography.bodySmall,
                    color = if (MaterialTheme.colorScheme.surface == Color(0xFF202124)) Color(0xFFFDE047) else Color(0xFF854D0E))
        }
        else -> Text(tr(R.string.exit_check_failed), style = MaterialTheme.typography.bodySmall, color = muted)
    }
}

// Protocol, transport and security of a server's first proxy outbound; empty parts are "".
private fun protocolParts(node: JSONObject): List<String> {
    val outbound = node.mapObject("config").objects("outbounds").firstOrNull { it.string("protocol") !in listOf("freedom", "blackhole", "dns") }
    val protocol = if (node.string("format") == "telegram") "Telegram" else outbound?.string("protocol").orEmpty()
    val stream = outbound?.mapObject("streamSettings")
    val transport = if (protocol == "tuic") "QUIC" else stream?.string("network").orEmpty()
    val security = if (protocol == "tuic") "TLS" else stream?.string("security").orEmpty().takeUnless { it == "none" }.orEmpty()
    return listOf(protocol, transport, security)
}

@Composable private fun ServerProtocol(node: JSONObject, provider: String? = null) {
    val (protocol, transport, security) = protocolParts(node)
    // Each server takes two lines, with Home's provider on this one. ListItem counts
    // differing first and last baselines as a third line, so both texts share one baseline.
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Surface(Modifier.alignByBaseline(), color = MaterialTheme.colorScheme.surfaceContainerLow, shape = MaterialTheme.shapes.extraSmall) {
            Text(protocol.uppercase(), Modifier.padding(horizontal = 6.dp, vertical = 3.dp), style = MaterialTheme.typography.labelSmall)
        }
        Text(listOf(transport, security, provider.orEmpty()).filter(String::isNotEmpty).joinToString(" · "), Modifier.alignByBaseline(), style = MaterialTheme.typography.bodySmall, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable private fun LatencyBadge(milliseconds: Long, modifier: Modifier = Modifier, label: String = "$milliseconds milliseconds") {
    val dark = MaterialTheme.colorScheme.surface == Color(0xFF202124)
    val (foreground, background) = when {
        milliseconds < 100 -> if (dark) Color(0xFF86EFAC) to Color(0xFF173B29) else Color(0xFF166534) to Color(0xFFDCFCE7)
        milliseconds < 300 -> if (dark) Color(0xFFFDE047) to Color(0xFF453810) else Color(0xFF854D0E) to Color(0xFFFEF9C3)
        else -> if (dark) Color(0xFFFCA5A5) to Color(0xFF492326) else Color(0xFF991B1B) to Color(0xFFFEE2E2)
    }
    Surface(modifier.semantics { contentDescription = label }, color = background, shape = androidx.compose.foundation.shape.RoundedCornerShape(6.dp)) {
        Text(tr(R.string.ms_value, milliseconds), Modifier.padding(horizontal = 5.dp, vertical = 2.dp), color = foreground, style = MaterialTheme.typography.labelSmall, fontWeight = FontWeight.SemiBold)
    }
}

@Composable private fun SourcesScreen(catalog: Catalog, busy: Boolean, activity: MainActivity, navigate: (String, String) -> Unit) {
    PullToRefreshBox(isRefreshing = busy, onRefresh = { if (!busy) activity.refreshAll(catalog.sources.filter { it.has("url") }.map { it.string("id") }) }) {
    val sources = catalog.sources.sortedByDescending { it.optBoolean("pinned") }
    LazyColumn(state = tabListState(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 16.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (catalog.sources.isEmpty()) item { Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            RouteIcon("sources", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(tr(R.string.no_subscriptions), style = MaterialTheme.typography.titleLarge)
            Text(tr(R.string.import_a_provider_link_or_local), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        } }
        itemsIndexed(sources, key = { _, source -> source.string("id") }) { index, source ->
            ListItem(headlineContent = { Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) { Text(source.string("name"), Modifier.weight(1f), style = MaterialTheme.typography.titleMedium); if (source.optBoolean("pinned")) RouteIcon("pin", tr(R.string.pinned_subscription), MaterialTheme.colorScheme.onSurfaceVariant) } },
                supportingContent = { Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                    val count = source.objects("nodes").size
                    val attention = sourceAttention(source)
                    Text(buildAnnotatedString {
                        append(trPlural(R.plurals.server_count, count))
                        if (!source.has("url")) append(tr(R.string.local_group))
                        else if (attention != null) { append(" · "); withStyle(SpanStyle(color = attention.second, fontWeight = FontWeight.Medium)) { append(attention.first) } }
                    })
                    if (source.has("url")) SubscriptionQuota(source.mapObject("metadata"))
                } },
                leadingContent = { RouteIcon(if (source.has("url")) "shield" else "folder", color = MaterialTheme.colorScheme.onSurfaceVariant) }, trailingContent = { RouteIcon("forward", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
                modifier = Modifier.clip(segmentShape(index, sources.size)).clickable { navigate("source", source.string("id")) })
        }
    }
    }
}

// A working provider shows no status; only one that needs attention does.
@Composable private fun sourceAttention(source: JSONObject): Pair<String, Color>? = when (source.string("status")) {
    "needsApproval" -> tr(R.string.needs_your_approval) to if (MaterialTheme.colorScheme.surface == Color(0xFF202124)) Color(0xFFFDE047) else Color(0xFF854D0E)
    "failed" -> (if (source.isNull("refreshError")) tr(R.string.last_update_failed) else refreshLabel(source.getString("refreshError"))) to MaterialTheme.colorScheme.error
    else -> null
}

@Composable private fun DetailValue(label: String, value: String, caption: String? = null, actions: @Composable RowScope.() -> Unit = {}) {
    Column {
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(16.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
            Text(value, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.End)
            actions()
        }
        if (caption != null) Text(caption, Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.End)
    }
}

// Time left, data left and the remaining fraction, as the provider reports them.
private fun quota(metadata: JSONObject): Triple<String, String, Float?> {
    val total = metadata.optLong("total", -1)
    val upload = metadata.optLong("upload", -1); val download = metadata.optLong("download", -1)
    val remaining = if (total > 0 && upload >= 0 && download >= 0) (total - minOf(total, upload) - minOf(total, download)).coerceAtLeast(0) else null
    val label = when { total == 0L -> tr(R.string.unlimited); remaining == null -> tr(R.string.not_provided); remaining == 0L -> tr(R.string.data_exhausted); else -> tr(R.string.bytes_left, bytes(remaining)) }
    val fraction = when { total == 0L -> 1f; remaining != null -> (remaining.toDouble() / total).toFloat(); else -> null }
    val expires = metadata.optDouble("expire", Double.NaN)
    val time = when { !expires.isFinite() || expires < 0 -> tr(R.string.not_provided); expires == 0.0 -> tr(R.string.no_expiry); expires <= now() -> tr(R.string.expired); else -> DateFormat.getDateInstance(DateFormat.MEDIUM).format(Date((expires * 1000).toLong())) }
    return Triple(time, label, fraction)
}

@Composable private fun SubscriptionQuota(metadata: JSONObject) {
    val (time, label, fraction) = quota(metadata)
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        DetailValue(tr(R.string.time), time)
        DetailValue(tr(R.string.data), label)
        if (fraction != null) LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth().semantics { contentDescription = tr(R.string.data_remaining) })
    }
}

@Composable private fun RoutingAssignment(catalog: Catalog, sourceID: String, busy: Boolean, activity: MainActivity, title: String = tr(R.string.routing_profile)) {
    val provided = catalog.routes.any { it.string("id") == catalog.assignments.string(sourceID) && it.string("providerSubscriptionId") == sourceID }
    // Inside the tile: below it, the group's rounded clip cut the note's end.
    SettingsChoice(title, catalog.assignments.string(sourceID), listOf("") + catalog.routes.map { it.string("id") },
        labels = listOf(tr(R.string.provider_defaults)) + catalog.routes.map { it.string("name") }, enabled = !busy,
        below = if (provided) {{ Text(tr(R.string.set_by_your_provider), style = MaterialTheme.typography.bodySmall, fontSize = 11.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f)) }} else null) {
        activity.run("assignRouting", obj("id" to sourceID, "routeId" to it))
    }
}

@Composable private fun SourceScreen(catalog: Catalog, id: String, activity: MainActivity, busy: Boolean, pings: Map<String, JSONObject>, navigate: (String, String) -> Unit, confirm: (String, String, String, () -> Unit) -> Unit) {
    val source = catalog.sources.firstOrNull { it.string("id") == id }
    if (source == null) { EmptyDetail(); return }
    var selecting by rememberSaveable(id) { mutableStateOf(false) }
    var chosen by rememberSaveable(id) { mutableStateOf(listOf<String>()) }
    var name by rememberSaveable(id, source.string("name")) { mutableStateOf(source.string("name")) }
    var renaming by rememberSaveable { mutableStateOf(false) }
    var sharing by rememberSaveable { mutableStateOf(false) }
    var showingHidden by rememberSaveable { mutableStateOf(false) }
    val hidden = source.objects("hiddenNodes")
    val metadata = source.mapObject("metadata")
    val remote = source.has("url")
    val nodes = source.objects("nodes")
    LazyColumn(Modifier.fillMaxSize(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        item { Column(Modifier.padding(bottom = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val muted = MaterialTheme.colorScheme.onSurfaceVariant
        SettingsGroup {
            SettingsTile(tr(R.string.status), (if (!remote) tr(R.string.local_group_2) else sourceAttention(source)?.first ?: if (source.string("status") == "pending") tr(R.string.not_updated_yet) else tr(R.string.up_to_date)) +
                if (source.has("lastSuccessfulFetch")) " · " + tr(R.string.updated_on, date(source.optDouble("lastSuccessfulFetch"))) else "")
            if (!source.isNull("nextRefreshAt")) SettingsTile(tr(R.string.next_refresh), date(source.optDouble("nextRefreshAt")))
            if (remote) refreshes(source, catalog).let { (value, caption) ->
                SettingsTile(tr(R.string.refreshes), value, below = { Text(caption, style = MaterialTheme.typography.bodySmall, color = muted) },
                    trailing = { TextButton({ navigate("sourceOptions", id) }, enabled = !busy) { Text(tr(R.string.change)) } })
            }
            if (!source.isNull("refreshError")) {
                val code = source.getString("refreshError")
                val support = source.mapObject("links").string("support")
                SettingsTile(tr(R.string.refresh, refreshFailure(code, source.string("name"))), titleColor = MaterialTheme.colorScheme.error,
                    below = if (code in providerFaults && support.isNotEmpty()) {{ TextButton({ activity.openURL(support) }) { Text(tr(R.string.contact_provider)) } }} else null)
            }
        }
        val notices = listOf("announcement" to tr(R.string.notice), "directiveNotice" to tr(R.string.configuration_notice), "dnsNotice" to "DNS", "bannerText" to tr(R.string.message)).filter { metadata.string(it.first).isNotEmpty() }
        val facts = listOf("enabled" to tr(R.string.account_enabled), "online" to tr(R.string.online)).filter { metadata.has(it.first) }
        val links = source.mapObject("links").let { links -> listOf("support" to tr(R.string.support), "account" to tr(R.string.account), "banner" to metadata.string("bannerButtonText", tr(R.string.open_provider_page))).filter { links.string(it.first).isNotEmpty() }.map { (key, title) -> title to links.getString(key) } }
        if (remote || notices.isNotEmpty() || facts.isNotEmpty()) SettingsGroup(tr(R.string.provider)) {
            if (remote) {
                val (time, data, fraction) = quota(metadata)
                SettingsTile(tr(R.string.time), time)
                SettingsTile(tr(R.string.data), data, below = if (fraction == null) null else {{ LinearProgressIndicator(progress = { fraction }, modifier = Modifier.fillMaxWidth().padding(top = 8.dp).semantics { contentDescription = tr(R.string.data_remaining) }) }})
            }
            notices.forEach { (key, title) -> SettingsTile(title, when (key) { "directiveNotice" -> tr(R.string.unsupported_provider_directives); "dnsNotice" -> tr(R.string.provider_dns_notice); else -> metadata.string(key) }) }
            facts.forEach { (key, title) -> SettingsTile(title, if (metadata.optBoolean(key)) tr(R.string.yes) else tr(R.string.no)) }
            if (metadata.has("routingEnabled") && !metadata.optBoolean("routingEnabled")) SettingsTile(tr(R.string.provider_routing_is_disabled))
        }
        if (remote) {
            val deviceID = remember(id, catalog.data.string("installationID"), source.string("url"), source.string("format"), source.string("deviceSalt"), source.mapObject("fetchOptions").string("httpHost")) {
                runCatching { catalog.deviceID(id) }.getOrNull()
            }
            SettingsGroup(footer = tr(R.string.elarni_sends_each_provider_a_different)) {
                SettingsTile(tr(R.string.device_id), deviceID?.let { "${it.take(8)}…${it.takeLast(4)}" } ?: tr(R.string.unavailable),
                    below = if (metadata.optBoolean("deviceRegistered")) {{ Text(tr(R.string.registered_set_by_your_provider), style = MaterialTheme.typography.bodySmall, color = muted) }} else null,
                    trailing = { Row {
                        TextButton({ deviceID?.let { activity.copy(it) } }, enabled = deviceID != null) { Text(tr(R.string.copy)) }
                        TextButton({
                            val title = source.string("name")
                            confirm(tr(R.string.reset_device_id_for, title), tr(R.string.will_see_this_device_as_new, title), tr(R.string.reset)) {
                                activity.run("resetDeviceID", obj("id" to id))
                            }
                        }, enabled = !busy) { Text(tr(R.string.reset)) }
                    } })
            }
        }
        // Provider links sit side by side, like the action buttons on Android's App info.
        if (links.isNotEmpty()) Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            links.forEach { (title, url) -> FilledTonalButton({ activity.openURL(url) }, Modifier.weight(1f).heightIn(min = 48.dp)) { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) } }
        }
        SettingsGroup(tr(R.string.routing)) { RoutingAssignment(catalog, id, busy, activity) }
        SettingsGroup {
            if (remote) {
                SettingsTile(tr(R.string.refresh_2), icon = "refresh", enabled = !busy) { activity.run("refresh", obj("id" to id)) }
                val formats = listOf("source", "raw", "json", "clash").filter { it == "source" || source.mapObject("links").has(it) }
                SettingsChoice(tr(R.string.download_format), source.string("format", "source"), formats, formats.map { when (it) { "source" -> tr(R.string.original); "raw" -> tr(R.string.share_links); "json" -> "Xray JSON"; else -> "Clash" } }, enabled = !busy) { activity.run("refresh", obj("id" to id, "format" to it)) }
                SettingsTile(tr(R.string.download_options), enabled = !busy) { navigate("sourceOptions", id) }
            }
            SettingsSwitch(tr(R.string.pin_subscription), source.optBoolean("pinned"), enabled = !busy) { activity.run("pinSource", obj("id" to id, "value" to it)) }
            SettingsTile(tr(R.string.rename), enabled = !busy) { name = source.string("name"); renaming = true }
            SettingsTile(tr(R.string.share), enabled = !busy) { if (remote) activity.run("share", obj("id" to id, "subscription" to true)) { activity.interaction.share = it } else sharing = true }
        }
        SettingsGroup {
            SettingsTile(tr(R.string.delete_subscription), enabled = !busy, titleColor = MaterialTheme.colorScheme.error) { confirm(tr(R.string.delete_this_subscription_and_its_servers), tr(R.string.if_it_contains_the_selected_server), tr(R.string.delete)) { activity.run("deleteSource", obj("id" to id)) { navigate("", "") } } }
        }
        SettingsGroup(tr(R.string.servers)) {
            SettingsTile(tr(R.string.browse_subscription_servers), trPlural(R.plurals.server_count, nodes.size)) { navigate("sourceNodes", id) }
            if (selecting) {
                val ids = nodes.map { it.string("id") }.filter { it in chosen }
                val count = trPlural(R.plurals.server_count, ids.size)
                SettingsTile(tr(R.string.selected_count, ids.size), below = { FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    // As on the desktop: a failed latest test, and never the selected server, which the catalog keeps.
                    TextButton({ chosen = (chosen + nodes.map { it.string("id") }.filter { nodeID -> nodeID != catalog.selected && pings[nodeID]?.let { it.string("status") != "success" || it.optLong("latencyMs", -1) < 0 } == true }).distinct() }) { Text(tr(R.string.select_unreachable)) }
                    TextButton({
                        confirm(if (remote) tr(R.string.hide, count) else tr(R.string.delete_2, count), if (remote) tr(R.string.they_stay_hidden_after_refreshes_show) else tr(R.string.they_are_removed_from, source.string("name")), if (remote) tr(R.string.hide_2) else tr(R.string.delete)) {
                            activity.run("deleteNodes", obj("ids" to JSONArray(ids))) { selecting = false; chosen = emptyList() }
                        }
                    }, enabled = !busy && ids.isNotEmpty() && ids.size < nodes.size) { Text(if (remote) tr(R.string.hide_2) else tr(R.string.delete), color = MaterialTheme.colorScheme.error) }
                    TextButton({ selecting = false; chosen = emptyList() }) { Text(tr(R.string.cancel)) }
                } })
            } else {
                SettingsTile(tr(R.string.test_subscription_servers), enabled = !busy) { navigate("sourcePing", id) }
                if (nodes.size > 1) SettingsTile(tr(R.string.select_servers), enabled = !busy) { selecting = true; chosen = emptyList() }
            }
        }
        } }
        itemsIndexed(nodes, key = { _, node -> node.string("id") }) { index, node ->
            val nodeID = node.string("id")
            val shape = Modifier.clip(segmentShape(index, nodes.size))
            val colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh)
            if (selecting) {
                val enabled = nodeID != catalog.selected
                ListItem(headlineContent = { Text(node.string("name")) }, supportingContent = { ServerProtocol(node) },
                    leadingContent = { Checkbox(nodeID in chosen, null, enabled = enabled) }, colors = colors,
                    modifier = shape.testTag("select-node-$nodeID").toggleable(nodeID in chosen, enabled = enabled, role = Role.Checkbox) { chosen = if (it) chosen + nodeID else chosen - nodeID })
            } else ListItem(headlineContent = { Text(node.string("name")) }, supportingContent = { ServerProtocol(node) },
                trailingContent = { RouteIcon(if (catalog.selected == nodeID) "check" else "forward", color = MaterialTheme.colorScheme.primary) }, colors = colors,
                modifier = shape.clickable { navigate("node", nodeID) })
        }
        if (hidden.isNotEmpty()) item {
            ListItem(headlineContent = { Text(tr(R.string.hidden_servers, hidden.size)) }, trailingContent = { TextButton({ showingHidden = true }, enabled = !busy) { Text(tr(R.string.show_again)) } })
        }
    }
    if (showingHidden && hidden.isNotEmpty()) AlertDialog(onDismissRequest = { showingHidden = false }, title = { Text(tr(R.string.hidden_servers_2)) }, text = {
        Column(Modifier.verticalScroll(rememberScrollState())) {
            hidden.forEach { node ->
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(node.string("name"), Modifier.weight(1f))
                    TextButton({ showingHidden = false; activity.run("showNode", obj("id" to node.string("id"))) }, enabled = !busy) { Text(tr(R.string.show_again)) }
                }
            }
        }
    }, confirmButton = { TextButton({ showingHidden = false }) { Text(tr(R.string.close)) } })
    if (renaming) AlertDialog(onDismissRequest = { if (!busy) renaming = false }, title = { Text(tr(R.string.rename_subscription)) }, text = {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedTextField(name, { name = it }, label = { Text(tr(R.string.name)) }, modifier = Modifier.fillMaxWidth())
            if (source.has("url") && source.has("manualName")) TextButton({ renaming = false; activity.run("renameSource", obj("id" to id, "name" to "")) }, enabled = !busy) { Text(tr(R.string.use_provider_name)) }
        }
    }, confirmButton = { TextButton({ renaming = false; activity.run("renameSource", obj("id" to id, "name" to name)) }, enabled = !busy && name.trim().isNotEmpty()) { Text(tr(R.string.save)) } }, dismissButton = { TextButton({ renaming = false }, enabled = !busy) { Text(tr(R.string.cancel)) } })
    if (sharing) ShareServersSheet(catalog, source, activity, busy) { sharing = false }
}

// A local group has no subscription link, so it shares the links of the servers chosen here.
@OptIn(ExperimentalMaterial3Api::class)
@Composable private fun ShareServersSheet(catalog: Catalog, source: JSONObject, activity: MainActivity, busy: Boolean, dismiss: () -> Unit) {
    val nodes = source.objects("nodes").filter(catalog::linkable)
    var chosen by rememberSaveable(source.string("id")) { mutableStateOf(nodes.map { it.string("id") }) }
    val ids = nodes.map { it.string("id") }.filter { it in chosen }
    ModalBottomSheet(onDismissRequest = dismiss) {
        Column(Modifier.verticalScroll(rememberScrollState()).padding(start = 24.dp, end = 24.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(tr(R.string.share_servers), style = MaterialTheme.typography.headlineSmall)
            // Only says why some servers are missing from the list.
            if (nodes.size < source.objects("nodes").size) Text(tr(R.string.profiles_with_several_outbounds_are_shared).trim(),
                style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
            nodes.forEach { node ->
                val nodeId = node.string("id")
                Row(Modifier.fillMaxWidth().heightIn(min = 48.dp).toggleable(nodeId in chosen, role = Role.Checkbox) { chosen = if (it) chosen + nodeId else chosen - nodeId },
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(16.dp)) {
                    Checkbox(nodeId in chosen, null)
                    Text(node.string("name"), Modifier.weight(1f))
                    ServerProtocol(node)
                }
            }
            Button({ activity.run("shareLinks", obj("ids" to JSONArray(ids))) { dismiss(); activity.interaction.share = it } },
                enabled = !busy && ids.isNotEmpty(), modifier = Modifier.fillMaxWidth().heightIn(min = 48.dp)) {
                Text(trPlural(R.plurals.share_links, ids.size))
            }
        }
    }
}

@Composable private fun NodeScreen(catalog: Catalog, id: String, activity: MainActivity, state: AppState, navigate: (String, String) -> Unit, done: () -> Unit, confirm: (String, String, String, () -> Unit) -> Unit) {
    val node = catalog.nodes.firstOrNull { it.string("id") == id }
    if (node == null) { EmptyDetail(); return }
    val telegram = node.string("format") == "telegram"
    // A provider's server is hidden, so that its refresh keeps it out.
    val remote = catalog.sourceFor(id).has("url")
    SettingsColumn {
        SettingsGroup {
            SettingsText(tr(R.string.name), node.string("name"), enabled = !state.busy) { activity.run("renameNode", obj("id" to id, "name" to it)) }
            val (protocol, transport, security) = protocolParts(node)
            SettingsTile(tr(R.string.protocol), listOf(protocol.uppercase(), transport, security).filter(String::isNotEmpty).joinToString(" · "))
            if (node.has("lastSuccessAt")) SettingsTile(tr(R.string.last_connected_title), date(node.optDouble("lastSuccessAt")))
        }
        if (telegram) Button({ activity.openURL(node.mapObject("config").string("url"), true) }, Modifier.fillMaxWidth().heightIn(min = 48.dp)) { Text(tr(R.string.open_in_telegram)) }
        else Button({ activity.run("select", obj("id" to id)) { done() } }, Modifier.fillMaxWidth().heightIn(min = 48.dp), enabled = !state.busy) { Text(if (catalog.selected == id) tr(R.string.selected_server) else tr(R.string.use_server)) }
        SettingsGroup {
            SettingsSwitch(tr(R.string.favorite), node.optBoolean("favorite")) { activity.run("favorite", obj("id" to id, "value" to it)) }
            if (!telegram) {
                SettingsChoice(tr(R.string.ip_preference), node.string("ipPreference", "inherit"), listOf("inherit", "automatic", "ipv4", "ipv6"), listOf(tr(R.string.use_app_default), tr(R.string.automatic), "IPv4", "IPv6")) { activity.run("nodeIP", obj("id" to id, "value" to it)) }
                node.mapObject("config").objects("elarniGroups").forEach { group -> SettingsChoice(group.string("name"), group.string("selected"), group.strings("options")) { activity.run("group", obj("id" to id, "group" to group.string("name"), "choice" to it)) } }
                SettingsTile(tr(R.string.test_this_server), enabled = !state.busy) { activity.testServers(listOf(id)) }
                SettingsTile(tr(R.string.check_exit), enabled = !state.busy, below = state.exits[id]?.let { exit -> { ExitLine(node, exit, remember { ServerLocations(activity) }) } }) { activity.checkExit(id) }
            }
        }
        SettingsGroup {
            SettingsTile(tr(R.string.share_profile_qr), enabled = !state.busy) { activity.run("share", obj("id" to id)) { activity.interaction.share = it } }
            SettingsTile(if (remote) tr(R.string.hide_server_2) else tr(R.string.delete_server_2), enabled = !state.busy, titleColor = MaterialTheme.colorScheme.error) {
                if (remote) confirm(tr(R.string.hide_server), tr(R.string.stays_hidden_after_refreshes_show_it, node.string("name")), tr(R.string.hide_2)) { activity.run("deleteNode", obj("id" to id)) { navigate("", "") } }
                else confirm(tr(R.string.delete_server), tr(R.string.delete_2, node.string("name")), tr(R.string.delete)) { activity.run("deleteNode", obj("id" to id)) { navigate("", "") } }
            }
        }
    }
}

@Composable private fun RoutingScreen(catalog: Catalog, busy: Boolean, activity: MainActivity, navigate: (String, String) -> Unit) {
    LazyColumn(state = tabListState(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 8.dp, bottom = 24.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        if (catalog.routes.isEmpty()) item { Column(Modifier.fillMaxWidth().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
            RouteIcon("routing", color = MaterialTheme.colorScheme.onSurfaceVariant)
            Text(tr(R.string.your_routing_your_choice), style = MaterialTheme.typography.titleLarge)
            Text(tr(R.string.create_rules_for_direct_proxy_and), color = MaterialTheme.colorScheme.onSurfaceVariant, textAlign = TextAlign.Center)
        } }
        itemsIndexed(catalog.routes, key = { _, route -> route.string("id") }) { index, route ->
            val assigned = catalog.sources.count { catalog.assignments.string(it.string("id")) == route.string("id") }
            val assignment = if (assigned == 0) tr(R.string.not_assigned) else trPlural(R.plurals.assigned_subscriptions, assigned)
            ListItem(headlineContent = { Text(route.string("name"), style = MaterialTheme.typography.titleMedium) }, supportingContent = {
                Text(listOf(if (route.optBoolean("enabled", true)) tr(R.string.enabled) else tr(R.string.disabled), if (route.string("providerSubscriptionId").isEmpty()) tr(R.string.manual) else tr(R.string.provider), if (route.optBoolean("edited")) tr(R.string.edited) else "", assignment).filter(String::isNotEmpty).joinToString(" · "))
            }, leadingContent = { RouteIcon("routing", color = MaterialTheme.colorScheme.onSurfaceVariant) }, trailingContent = { RouteIcon("forward", color = MaterialTheme.colorScheme.onSurfaceVariant) },
                colors = ListItemDefaults.colors(containerColor = MaterialTheme.colorScheme.surfaceContainerHigh),
                modifier = Modifier.clip(segmentShape(index, catalog.routes.size)).testTag("routing-${route.string("id")}").clickable { navigate("routeDetail", route.string("id")) })
        }
        if (catalog.sources.isNotEmpty()) item {
            Box(Modifier.padding(top = 6.dp)) { SettingsGroup(tr(R.string.assignments)) { catalog.sources.forEach { RoutingAssignment(catalog, it.string("id"), busy, activity, it.string("name")) } } }
        }
    }
}

@Composable private fun RoutingDetailScreen(catalog: Catalog, id: String, busy: Boolean, activity: MainActivity,
    navigate: (String, String) -> Unit, confirm: (String, String, () -> Unit) -> Unit) {
    val route = catalog.routes.firstOrNull { it.string("id") == id }
    if (route == null) { EmptyDetail(); return }
    var reset by remember { mutableStateOf(false) }
    var assign by remember { mutableStateOf(false) }
    val assigned = catalog.sources.filter { catalog.assignments.string(it.string("id")) == id }
    val provider = route.string("providerSubscriptionId")
    SettingsColumn {
        SettingsGroup {
            SettingsSwitch(tr(R.string.enabled), route.optBoolean("enabled", true), enabled = !busy) { activity.run("enableRouting", obj("id" to id, "value" to it)) }
            if (provider.isNotEmpty()) SettingsTile(tr(R.string.provider), (catalog.sources.firstOrNull { it.string("id") == provider }?.string("name") ?: tr(R.string.unavailable)) + if (route.optBoolean("edited")) " · " + tr(R.string.local_override) else "")
        }
        SettingsGroup {
            SettingsTile(tr(R.string.edit_rules_and_dns), icon = "settings", enabled = !busy) { navigate("route", id) }
            SettingsTile(tr(R.string.edit_json), icon = "code", enabled = !busy) { navigate("routeJSON", id) }
            SettingsTile(tr(R.string.share_routing_profile), enabled = !busy) { activity.run("exportRouting", obj("id" to id)) { activity.shareText(it.getString("text")) } }
            SettingsTile(tr(R.string.duplicate), enabled = !busy) { activity.run("duplicateRouting", obj("id" to id)) }
            SettingsTile(tr(R.string.export_json), enabled = !busy) { activity.run("exportRouting", obj("id" to id)) { activity.save(it.getString("text"), "elarni-routing.json") } }
        }
        SettingsGroup(tr(R.string.assignments)) {
            Box {
                SettingsTile(tr(R.string.assign_to_subscription), when { catalog.sources.isEmpty() -> tr(R.string.no_subscriptions); assigned.isEmpty() -> tr(R.string.not_assigned); else -> tr(R.string.assigned_to, assigned.joinToString { it.string("name") }) },
                    enabled = !busy && catalog.sources.isNotEmpty()) { assign = true }
                DropdownMenu(assign, { assign = false }) {
                    catalog.sources.forEach { source ->
                        DropdownMenuItem({ Text(source.string("name")) }, {
                            assign = false
                            activity.run("assignRouting", obj("id" to source.string("id"), "routeId" to id))
                        }, enabled = !busy && catalog.assignments.string(source.string("id")) != id)
                    }
                }
            }
        }
        SettingsGroup(tr(R.string.routing_data), route.strings("skippedGeodata").takeIf { it.isNotEmpty() }?.let { tr(R.string.direct_block_and_domestic_dns_rules, it.joinToString(", ")) }.orEmpty()) {
            SettingsTile(tr(R.string.status), route.string("geofileStatus", tr(R.string.not_downloaded)))
            if (!route.isNull("geofileError")) SettingsTile(errorMessage(route.string("geofileError")), titleColor = MaterialTheme.colorScheme.error)
            route.objects("geofiles").forEach { file ->
                SettingsTile(file.string("name", tr(R.string.file)), listOfNotNull(file.string("source", tr(R.string.not_configured)), if (file.has("bytes")) bytes(file.optLong("bytes")) else null, if (file.has("updatedAt")) date(file.optDouble("updatedAt")) else tr(R.string.never)).joinToString("\n"),
                    trailing = { IconButton({ activity.run("refreshGeofiles", obj("id" to id, "kind" to file.string("name"))) }, enabled = !busy) { RouteIcon("refresh", tr(R.string.refresh_2_2, file.string("name", "file")), MaterialTheme.colorScheme.primary) } })
            }
            SettingsTile(tr(R.string.refresh_all_routing_data), icon = "refresh", enabled = !busy) { activity.run("refreshGeofiles", obj("id" to id)) }
        }
        val sources = route.mapObject("profile").objects("ManagedSources")
        if (sources.isNotEmpty()) SettingsGroup(tr(R.string.managed_domain_lists)) {
            if (!route.isNull("managedError")) SettingsTile(errorMessage(route.string("managedError")), titleColor = MaterialTheme.colorScheme.error)
            sources.forEach { source ->
                val host = android.net.Uri.parse(source.string("url")).host ?: tr(R.string.domain_list)
                val destination = when (source.string("destination")) { "block" -> tr(R.string.block_word); "direct" -> tr(R.string.direct_word); "proxy" -> tr(R.string.proxy_word); "dns" -> tr(R.string.direct_dns_word); else -> source.string("destination").replaceFirstChar { it.uppercase() } }
                SettingsTile(host, "$destination · ${if (source.string("matchMode") == "exact") tr(R.string.exact_domains_label) else tr(R.string.including_subdomains)}",
                    trailing = { IconButton({ activity.run("refreshManaged", obj("id" to id, "sourceId" to source.string("id"))) }, enabled = !busy) { RouteIcon("refresh", tr(R.string.refresh_2_2, host), MaterialTheme.colorScheme.primary) } })
            }
            SettingsTile(tr(R.string.refresh_lists), icon = "refresh", enabled = !busy) { activity.run("refreshManaged", obj("id" to id)) }
        }
        SettingsGroup {
            if (provider.isNotEmpty() || route.optBoolean("edited")) SettingsTile(if (provider.isNotEmpty()) tr(R.string.reset_to_provider_version) else tr(R.string.reset_to_original), enabled = !busy) { reset = true }
            SettingsTile(tr(R.string.delete_routing_profile), enabled = !busy, titleColor = MaterialTheme.colorScheme.error) { confirm(tr(R.string.delete_this_routing_profile), tr(R.string.subscriptions_using_it_return_to_their)) { activity.run("deleteRouting", obj("id" to id)) { navigate("", "") } } }
        }
    }
    if (reset) AlertDialog(onDismissRequest = { reset = false }, title = { Text(tr(R.string.reset_routing_profile)) }, text = { Text(tr(R.string.this_discards_your_local_edits_and)) },
        confirmButton = { TextButton({ reset = false; activity.run("resetRouting", obj("id" to id)) }) { Text(tr(R.string.reset)) } }, dismissButton = { TextButton({ reset = false }) { Text(tr(R.string.cancel)) } })
}

@Composable private fun SettingsScreen(catalog: Catalog, activity: MainActivity, navigate: (String, String) -> Unit) {
    LazyColumn(state = tabListState(), contentPadding = PaddingValues(start = 16.dp, end = 16.dp, bottom = 32.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        item { SettingsGroup(tr(R.string.preferences)) {
            SettingsTile(Settings.sectionTitle("General"), icon = "settings") { navigate("settingsEditor", "General") }
            SettingsTile(Settings.sectionTitle("Appearance"), icon = "appearance") { navigate("settingsEditor", "Appearance") }
        } }
        item { SettingsGroup(tr(R.string.network)) {
            listOf("Connection", "DNS", "Apps & routes", "Advanced", "Server tests").forEach { section ->
                SettingsTile(Settings.sectionTitle(section), icon = when (section) { "DNS" -> "dns"; "Apps & routes" -> "routing"; "Connection" -> "power"; "Server tests" -> "ping"; "Advanced" -> "code"; else -> "settings" }) { navigate("settingsEditor", section) }
            }
        } }
        item { SettingsGroup(tr(R.string.support)) {
            SettingsTile(tr(R.string.backup_and_repair), icon = "lock") { navigate("backupSupport", "") }
            SettingsTile(tr(R.string.system_info), icon = "info") { navigate("systemInfo", "") }
            SettingsTile(tr(R.string.route_table), icon = "table") { navigate("routeTable", "") }
        } }
    }
}

@Composable private fun BackupSupportScreen(state: AppState, activity: MainActivity, navigate: (String, String) -> Unit) {
    val active = state.connection in listOf("connected", "connecting", "paused", "disconnecting")
    var repair by remember { mutableStateOf(false) }
    SettingsColumn {
        SettingsGroup(tr(R.string.encrypted_backup), tr(R.string.backups_contain_subscriptions_servers_and_routing)) {
            SettingsTile(tr(R.string.create_encrypted_backup), enabled = !state.busy) { navigate("backup", "") }
            SettingsTile(tr(R.string.restore_backup), tr(R.string.replaces_the_catalog_disables_automatic_recovery), enabled = !state.busy && !active) { activity.pick("restore") }
        }
        SettingsGroup(tr(R.string.connection_repair)) {
            SettingsTile(tr(R.string.reset_connection), tr(R.string.stops_automatic_recovery_and_clears_the),
                enabled = !state.busy && !active, titleColor = MaterialTheme.colorScheme.error) { repair = true }
            SettingsTile(tr(R.string.troubleshooting)) { navigate("diagnostics", "") }
            SettingsTile(tr(R.string.logs), tr(R.string.the_core_s_own_messages_with)) { navigate("logs", "") }
            SettingsTile(tr(R.string.export_diagnostics), enabled = !state.busy) { activity.run("diagnostics") { activity.save(it.getString("text"), "elarni-diagnostics.json") } }
        }
    }
    if (repair) AlertDialog(onDismissRequest = { repair = false }, title = { Text(tr(R.string.reset_connection_2)) },
        text = { Text(tr(R.string.automatic_recovery_will_stop_your_saved)) },
        confirmButton = { TextButton({ repair = false; activity.run("repair") { activity.interaction.notice = tr(R.string.connection_reset_tap_connect_when_you) } }) { Text(tr(R.string.reset)) } },
        dismissButton = { TextButton({ repair = false }) { Text(tr(R.string.cancel)) } })
}

@Composable private fun NoticesScreen(activity: MainActivity) {
    val documents = listOf("NOTICE" to "Elarni", "LICENSE" to tr(R.string.gpl_license), "THIRD_PARTY_NOTICES" to tr(R.string.shared_components), "OPEN_SOURCE_NOTICES" to tr(R.string.android_components))
    var selected by rememberSaveable { mutableStateOf("NOTICE") }
    var paragraphs by remember { mutableStateOf<List<String>>(emptyList()) }
    LaunchedEffect(selected) {
        paragraphs = emptyList()
        paragraphs = withContext(Dispatchers.IO) {
            runCatching { activity.assets.open(selected).bufferedReader().use { it.readText() }.split("\n\n") }
                .getOrElse { listOf(tr(R.string.the_license_document_could_not_be)) }
        }
    }
    LazyColumn(contentPadding = PaddingValues(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        item { FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            documents.forEach { (file, label) -> FilterChip(selected == file, { selected = file }, label = { Text(label) }) }
        } }
        items(paragraphs) { paragraph -> SelectionContainer { Text(paragraph, style = MaterialTheme.typography.bodySmall) } }
    }
}

@Composable private fun ShareDialog(result: JSONObject, activity: MainActivity, dismiss: () -> Unit) {
    val png = result.string("png")
    val bitmap = remember(png) { if (png.isEmpty()) null else runCatching { val bytes = Base64.decode(png, Base64.DEFAULT); BitmapFactory.decodeByteArray(bytes, 0, bytes.size).asImageBitmap() }.getOrNull() }
    AlertDialog(onDismissRequest = dismiss, title = { Text(tr(R.string.share_profile)) }, text = { Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text(tr(R.string.anyone_with_this_profile_can_use))
        if (bitmap != null) Image(bitmap, tr(R.string.connection_qr_code), Modifier.fillMaxWidth().aspectRatio(1f)) else Text(tr(R.string.this_profile_is_too_large_for))
        TextButton({ activity.copy(result.getString("text")) }) { Text(tr(R.string.copy_profile)) }
        TextButton({ activity.save(result.getString("text"), "elarni-profile.txt") }) { Text(tr(R.string.save_profile_file)) }
        if (bitmap != null) TextButton({ activity.shareQR(png) }) { Text(tr(R.string.share_qr_image)) }
    } }, confirmButton = { TextButton({ activity.shareText(result.getString("text")) }) { Text(tr(R.string.share_text)) } }, dismissButton = { TextButton(dismiss) { Text(tr(R.string.done)) } })
}

@Composable fun EmptyDetail() { Text(tr(R.string.item_no_longer_in_catalog), Modifier.padding(24.dp)) }
@Composable fun rememberClock(): State<Double> = produceState(now()) { while (true) { delay(30_000); value = now() } }
fun pingFresh(node: JSONObject, result: JSONObject, time: Double) = result.string("configurationRevision") == node.string("configurationRevision", node.string("id")) && time - result.optDouble("timestamp", 0.0) in 0.0..300.0
fun pingScope(result: JSONObject) = when (result.string("protocol")) { "tcp" -> tr(R.string.direct_tcp); "icmp" -> tr(R.string.direct_icmp); "activeProxy" -> tr(R.string.active_proxy); else -> "proxy" }

@Composable private fun DiagnosticsScreen(page: String, state: AppState, activity: MainActivity, navigate: (String, String) -> Unit) {
    var info by remember(page) { mutableStateOf<JSONObject?>(null) }
    fun refresh() { activity.run(if (page == "diagnostics") "read" else page) { info = it } }
    LaunchedEffect(page) { refresh() }
    SettingsColumn {
        if (page == "diagnostics") {
            SettingsGroup {
                SettingsTile(tr(R.string.connection_2), state.connection)
                SettingsTile(tr(R.string.connection_recovery), state.automationStatus)
                if (state.whitelistMode) SettingsTile(tr(R.string.whitelist_mode_russian_entry_servers_first))
                state.error?.let { SettingsTile(errorMessage(it), titleColor = MaterialTheme.colorScheme.error) }
            }
            SettingsGroup {
                SettingsTile(tr(R.string.retry_selected_server), enabled = !state.busy) { activity.connect() }
                SettingsTile(tr(R.string.check_selected_server)) { navigate("ping", Catalog(state.catalog).selected) }
                SettingsTile(tr(R.string.reset_connection), enabled = !state.busy) { activity.run("repair") { activity.interaction.notice = tr(R.string.connection_reset_tap_connect_when_you) } }
                SettingsTile(tr(R.string.open_android_vpn_settings)) { activity.vpnSettings() }
            }
            SettingsGroup(tr(R.string.recent_issues)) {
                if (state.issues.isEmpty()) SettingsTile(tr(R.string.no_issues_recorded_in_this_app))
                state.issues.forEach { SettingsTile(errorMessage(it.string("code")), date(it.optDouble("timestamp"))) }
            }
            SettingsGroup {
                SettingsTile(tr(R.string.export_diagnostics)) { activity.run("diagnostics") { activity.save(it.getString("text"), "elarni-diagnostics.json") } }
                SettingsTile(tr(R.string.logs)) { navigate("logs", "") }
            }
            if (BuildConfig.ELARNI_RECORDING) SettingsGroup(tr(R.string.connection_recording), tr(R.string.turn_on_record_connection_diagnostics_in)) {
                SettingsTile(tr(R.string.mark_a_problem_now), enabled = Catalog(state.catalog).settings.optBoolean("recordDiagnostics")) { activity.markRecording() }
                SettingsTile(tr(R.string.save_recording_as_zip)) { activity.saveRecording() }
            }
        } else {
            val value = info
            if (value == null) Text(tr(R.string.loading), Modifier.padding(horizontal = 20.dp))
            else if (page == "systemInfo") {
                SettingsGroup { listOf("platform" to tr(R.string.system), "sdk" to tr(R.string.api_level), "device" to tr(R.string.device), "app" to "Elarni", "core" to "Xray", "cores" to tr(R.string.cpu_cores)).forEach { (key, title) -> SettingsTile(title, value.opt(key).toString()) } }
                SettingsGroup {
                    SettingsTile(tr(R.string.vpn_permission), if (value.optBoolean("vpnConsent")) tr(R.string.granted) else tr(R.string.not_granted))
                    SettingsTile(tr(R.string.always_on_vpn), if (value.optBoolean("alwaysOn")) tr(R.string.on) else tr(R.string.off))
                    SettingsTile(tr(R.string.block_without_vpn), if (value.optBoolean("lockdown")) tr(R.string.on) else tr(R.string.off))
                    SettingsTile(tr(R.string.network), if (value.optBoolean("networkAvailable")) tr(R.string.available) else tr(R.string.unavailable))
                    SettingsTile(tr(R.string.architectures), value.strings("abis").joinToString())
                }
                SettingsGroup {
                    SettingsTile(tr(R.string.troubleshooting)) { navigate("diagnostics", "") }
                    SettingsTile(tr(R.string.export_diagnostics)) { activity.run("diagnostics") { activity.save(it.getString("text"), "elarni-diagnostics.json") } }
                    SettingsTile(tr(R.string.licenses_and_notices)) { navigate("notices", "") }
                }
            } else value.objects("networks").forEach { network ->
                SettingsGroup("${network.string("interface")} · ${if (network.optBoolean("vpn")) "VPN" else tr(R.string.physical_network)}") {
                    network.objects("routes").forEach { SettingsTile(it.string("destination") + it.string("gateway").takeIf { address -> address.isNotEmpty() }?.let { address -> tr(R.string.route_via, address) }.orEmpty()) }
                    SettingsTile(tr(R.string.dns_label), network.strings("dns").joinToString().ifEmpty { tr(R.string.none) })
                }
            }
            SettingsGroup { SettingsTile(tr(R.string.refresh_status), enabled = !state.busy, onClick = ::refresh) }
        }
    }
}
// The core runs in this process, so the screen reads its redacted lines directly, outside the catalog lock.
@Composable private fun LogsScreen(catalog: Catalog, busy: Boolean, activity: MainActivity) {
    val level = catalog.settings.string("logLevel", "warning")
    var lines by remember { mutableStateOf(listOf<JSONObject>()) }
    LaunchedEffect(Unit) {
        while (true) {
            val after = lines.lastOrNull()?.optLong("seq") ?: 0
            withContext(Dispatchers.IO) { runCatching { Native.call("readLogs", obj("after" to after)) }.getOrNull() }
                ?.let { read -> lines = (lines + read.objects("entries")).takeLast(1000) }
            delay(1000)
        }
    }
    fun text() = (listOf(tr(R.string.elarni_log_level, level)) + lines.map { "${java.time.Instant.ofEpochMilli(it.optLong("time"))} ${it.string("level").uppercase()} ${it.string("text")}" })
        .joinToString("\n")
    val clock = remember { DateFormat.getTimeInstance(DateFormat.MEDIUM) }
    Column(Modifier.fillMaxSize().padding(horizontal = 24.dp).padding(top = 12.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        ChoiceField(tr(R.string.level), level, Settings.logLevels, listOf(tr(R.string.off), tr(R.string.error), tr(R.string.warning), tr(R.string.info), tr(R.string.debug)), enabled = !busy) {
            activity.run("settings", obj("settings" to obj("logLevel" to it)))
        }
        Text(tr(R.string.keys_addresses_host_names_and_user), style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            TextButton({ activity.copy(text()) }, enabled = lines.isNotEmpty()) { Text(tr(R.string.copy)) }
            TextButton({ activity.shareFile("elarni-log.txt", "text/plain", tr(R.string.share_log)) { text().toByteArray(Charsets.UTF_8) } }, enabled = lines.isNotEmpty()) { Text(tr(R.string.share)) }
        }
        if (lines.isEmpty()) Text(if (level == "none") tr(R.string.logging_is_off_choose_a_level) else tr(R.string.no_log_lines_yet_the_core))
        SelectionContainer(Modifier.weight(1f)) {
            LazyColumn(contentPadding = PaddingValues(bottom = 100.dp), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                items(lines.asReversed(), key = { it.optLong("seq") }) { line ->
                    Text("${clock.format(Date(line.optLong("time")))} ${line.string("level").uppercase()} ${line.string("text")}",
                        fontFamily = androidx.compose.ui.text.font.FontFamily.Monospace, style = MaterialTheme.typography.bodySmall)
                }
            }
        }
    }
}

@Composable fun FormColumn(modifier: Modifier = Modifier, bottomPadding: androidx.compose.ui.unit.Dp = 100.dp, content: @Composable ColumnScope.() -> Unit) { Column(modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 24.dp).padding(top = 12.dp, bottom = bottomPadding), verticalArrangement = Arrangement.spacedBy(16.dp), content = content) }
fun bytes(value: Long): String = when { value >= 1024L*1024*1024 -> tr(R.string.size_gb).format(value / (1024.0*1024*1024)); value >= 1024*1024 -> tr(R.string.size_mb).format(value / (1024.0*1024)); value >= 1024 -> tr(R.string.size_kb).format(value / 1024.0); else -> tr(R.string.size_b, value) }
fun date(seconds: Double) = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT).format(Date((seconds * 1000).toLong()))
// Which interval schedules a subscription, as on desktop and iPhone.
private fun refreshes(source: JSONObject, catalog: Catalog): Pair<String, String> {
    val override = source.mapObject("fetchOptions").string("refreshHours").toIntOrNull()
    val provider = source.mapObject("metadata").optInt("updateIntervalHours")
    return when {
        override != null -> trPlural(R.plurals.every_hours, override) to tr(R.string.your_override_label)
        provider > 0 -> trPlural(R.plurals.every_hours, provider) to tr(R.string.set_by_provider_label)
        else -> trPlural(R.plurals.every_hours, catalog.settings.getInt("subscriptionAutoUpdateHours")) to tr(R.string.app_setting_label)
    }
}

// A failed download's short label, as on desktop and iPhone.
private fun refreshLabel(code: String) = when (code) {
    "fetch_failed" -> tr(R.string.download_failed)
    "dns_failed" -> tr(R.string.address_lookup_failed)
    "provider_unreachable" -> tr(R.string.provider_unreachable)
    "provider_error" -> tr(R.string.provider_error)
    "rate_limited" -> tr(R.string.rate_limited)
    "subscription_denied" -> tr(R.string.access_refused)
    "subscription_unavailable" -> tr(R.string.link_removed)
    else -> tr(R.string.last_update_failed)
}
/** Failures only the provider can fix, which offer its support link. */
private val providerFaults = setOf("provider_unreachable", "provider_error", "subscription_denied", "subscription_unavailable", "hwid_required", "hwid_limit")
/** A failed download in words that name the provider, so its outages are not reported as app bugs. */
private fun refreshFailure(code: String, provider: String) = when (code) {
    "hwid_required", "hwid_limit" -> tr(R.string.named_provider_device_limit, provider)
    "provider_unreachable" -> tr(R.string.named_provider_unreachable, provider)
    "provider_error" -> tr(R.string.named_provider_error, provider)
    "rate_limited" -> tr(R.string.named_provider_rate_limited, provider)
    "subscription_denied" -> tr(R.string.named_provider_denied, provider)
    "subscription_unavailable" -> tr(R.string.named_provider_link_removed, provider)
    "sharing_disabled" -> tr(R.string.named_provider_sharing_disabled, provider)
    else -> errorMessage(code)
}

fun errorMessage(code: String): String = when (code) {
    "cancelled", "fetch_cancelled", "probe_cancelled" -> tr(R.string.operation_cancelled_your_saved_configuration_is)
    "no_selection" -> tr(R.string.select_a_server_before_connecting)
    "vpn_consent_required" -> tr(R.string.allow_elarni_to_create_a_vpn)
    "vpn_revoked" -> tr(R.string.android_revoked_vpn_access_open_elarni)
    "vpn_network_unavailable" -> tr(R.string.android_has_not_made_the_vpn)
    "foreground_start_denied" -> tr(R.string.android_could_not_start_the_service)
    "storage_locked", "storage_corrupt", "storage_unavailable" -> tr(R.string.your_encrypted_catalog_could_not_be)
    "unsupported_profile", "invalid_input" -> tr(R.string.this_profile_could_not_be_imported)
    "connection_failed" -> tr(R.string.the_connection_could_not_start_check)
    "invalid_settings" -> tr(R.string.some_settings_are_invalid_check_port)
    "invalid_update_feed" -> tr(R.string.use_an_https_address_for_the)
    "invalid_trusted_wifi" -> tr(R.string.use_up_to_64_wi_fi)
    "per_app_target_missing" -> tr(R.string.an_app_in_per_app_routing)
    "invalid_per_app", "app_unavailable" -> tr(R.string.select_installed_android_apps_and_a)
    "invalid_automation" -> tr(R.string.check_the_automation_s_group_selected)
    "inbound_credentials_required" -> tr(R.string.save_a_proxy_username_and_password)
    "invalid_backup" -> tr(R.string.the_backup_or_password_is_invalid)
    "invalid_backup_password" -> tr(R.string.backup_passwords_need_12_to_1024)
    "disconnect_first" -> tr(R.string.disconnect_before_restoring_a_backup)
    "backup_unsupported" -> tr(R.string.this_catalog_cannot_be_backed_up)
    "catalog_limit" -> tr(R.string.elarni_keeps_up_to_1_024)
    "sharing_disabled" -> tr(R.string.the_provider_disabled_sharing_for_this)
    "sharing_refresh_required" -> tr(R.string.refresh_this_subscription_before_sharing_so)
    "approval_expired" -> tr(R.string.this_approval_expired_or_the_catalog)
    "input_too_large" -> tr(R.string.the_input_exceeds_the_supported_size)
    "invalid_qr_image" -> tr(R.string.no_readable_qr_code_was_found)
    "camera_unavailable" -> tr(R.string.no_camera_app_is_available_import)
    "file_unavailable" -> tr(R.string.the_file_could_not_be_read)
    "recording_empty" -> tr(R.string.nothing_is_recorded_yet_turn_on)
    "recording_failed" -> tr(R.string.the_recording_could_not_be_updated)
    "export_expired" -> tr(R.string.android_restarted_the_app_during_export)
    "link_unavailable" -> tr(R.string.no_app_could_open_this_link)
    "ping_failed" -> tr(R.string.the_server_test_failed_check_the)
    "probe_busy" -> tr(R.string.an_earlier_server_test_is_still)
    "unsupported_ping_method" -> tr(R.string.this_transport_does_not_support_that)
    "hwid_required", "hwid_limit" -> tr(R.string.the_provider_requires_device_registration_or)
    "fetch_failed" -> tr(R.string.the_download_failed_check_this_device)
    "dns_failed" -> tr(R.string.the_address_could_not_be_looked)
    "provider_unreachable" -> tr(R.string.the_provider_s_server_did_not)
    "provider_error" -> tr(R.string.the_provider_s_server_reported_an)
    "rate_limited" -> tr(R.string.the_provider_is_limiting_requests_elarni)
    "subscription_denied" -> tr(R.string.the_provider_refused_the_request_the)
    "subscription_unavailable" -> tr(R.string.the_provider_removed_or_changed_this)
    "not_connected" -> tr(R.string.connect_to_this_server_before_testing)
    "assets_unavailable", "invalid_assets", "invalid_geodata" -> tr(R.string.routing_data_is_missing_or_invalid)
    // RoutingAssets appends the missing codes to this code.
    else -> if (code.startsWith("missing_geodata:")) tr(R.string.proxy_rules_and_servers_need_codes, code.substringAfter(':').replace(",", ", "))
        else tr(R.string.the_operation_could_not_finish_check, code)
}
