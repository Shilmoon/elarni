package com.elarni

import android.app.Activity
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.ShortcutInfo
import android.content.pm.ShortcutManager
import android.graphics.drawable.Icon
import android.os.Bundle
import android.os.PowerManager
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject

// The widget, launcher shortcuts and automation apps connect without the app's screens.
const val ACTION_CONNECT = "com.elarni.action.CONNECT"
const val ACTION_DISCONNECT = "com.elarni.action.DISCONNECT"
const val ACTION_TOGGLE = "com.elarni.action.TOGGLE"
/** The string extra on those broadcasts: the control key from Settings › General. */
const val EXTRA_KEY = "key"
private val active = listOf("connected", "connecting", "paused")
private const val PENDING = PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT

// VpnService.prepare would take the VPN from another app whenever this one holds consent; read the consent itself.
fun vpnConsented(context: Context) = runCatching { context.getSystemService(android.app.AppOpsManager::class.java)
    .unsafeCheckOpNoThrow("android:activate_vpn", android.os.Process.myUid(), context.packageName) == android.app.AppOpsManager.MODE_ALLOWED }.getOrDefault(false)
/** Connecting outside the app needs a server and, for System VPN, the consent the app already holds. */
fun connectsWithoutApp(context: Context, catalog: Catalog) = catalog.selected.isNotEmpty() && (!catalog.settings.optBoolean("xrayTunEnabled") || vpnConsented(context))
fun statusLabel(connection: String, liveness: String?) = when (connection) {
    "connected" -> if (liveness == "noTraffic") tr(R.string.no_traffic) else tr(R.string.connected); "connecting" -> tr(R.string.connecting_2); "paused" -> tr(R.string.paused)
    "disconnecting" -> tr(R.string.disconnecting_2); "failed" -> tr(R.string.failed); else -> tr(R.string.disconnected)
}
fun openConnect(context: Context): Intent = Intent(context, MainActivity::class.java).setAction("com.elarni.OPEN_CONNECT").addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

/** Connects, disconnects or toggles; false when connecting needs the app: a server to choose or VPN consent. */
suspend fun ElarniApplication.control(action: String): Boolean {
    repository.awaitReady()
    val state = repository.state.value
    val catalog = Catalog(state.catalog)
    val running = state.connection in active
    if (action == ACTION_DISCONNECT || action == ACTION_TOGGLE && running) {
        if (state.connection != "disconnected" || catalog.data.optBoolean("connectionIntent")) repository.requestStop()
        return true
    }
    if (running) return true
    if (!connectsWithoutApp(this, catalog)) return false
    // VPN consent exempts this foreground-service start from Android 12+ background limits.
    try { repository.requestConnect() } catch (error: Exception) { if (error !is AppFailure || error.code != "cancelled") repository.report(error) }
    return true
}

/** Connect and Disconnect on a long press of the launcher icon. */
fun ElarniApplication.publishShortcuts() {
    val manager = getSystemService(ShortcutManager::class.java) ?: return
    val wanted = listOf("connect" to tr(R.string.connect), "disconnect" to tr(R.string.disconnect))
    // They persist, and setting them again from the background counts toward Android's rate limit; a new language relabels them.
    if (manager.dynamicShortcuts.map { it.id to it.shortLabel.toString() }.toSet() == wanted.toSet()) return
    // A convenience: it must never stop the app from starting.
    runCatching { manager.setDynamicShortcuts(wanted.mapIndexed { rank, (id, label) ->
        ShortcutInfo.Builder(this, id).setShortLabel(label).setRank(rank).setIcon(Icon.createWithResource(this, R.mipmap.ic_launcher))
            .setIntent(Intent(this, ShortcutActivity::class.java).setAction(if (id == "connect") ACTION_CONNECT else ACTION_DISCONNECT)).build()
    }) }
}

/** Launcher shortcuts start this as Elarni; it shows nothing, acts and finishes. */
class ShortcutActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (savedInstanceState != null) { finish(); return }
        val app = application as ElarniApplication
        val action = intent.action
        // It finishes after the action: while it shows, Android allows the connection's foreground service.
        app.repository.scope.launch {
            val done = action !in listOf(ACTION_CONNECT, ACTION_DISCONNECT) || app.control(action!!)
            withContext(Dispatchers.Main) { if (!done) startActivity(openConnect(this@ShortcutActivity)); finish() }
        }
    }
}

/** Explicit broadcasts from automation apps such as Tasker, honored only while the user allows them in Settings and they carry the key. */
class RemoteControl : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action?.takeIf { it in listOf(ACTION_CONNECT, ACTION_DISCONNECT, ACTION_TOGGLE) } ?: return
        // Any app may send this; extras of a class this app lacks throw while they unparcel.
        val key = runCatching { intent.getStringExtra(EXTRA_KEY) }.getOrNull()
        val result = goAsync(); val app = context.applicationContext as ElarniApplication
        app.repository.scope.launch {
            try {
                app.repository.awaitReady()
                val catalog = Catalog(app.repository.state.value.catalog)
                if (!catalog.settings.optBoolean("allowExternalControl")) return@launch
                // Not the user's failure: another app guessed or kept an old key.
                if (!authorized(catalog.data.string("externalControlKey"), key)) { refused(); return@launch }
                if (!app.control(action)) app.repository.report(AppFailure(if (catalog.selected.isEmpty()) "no_selection" else "vpn_consent_required"))
            } finally { result.finish() }
        }
    }
    companion object {
        @Volatile private var refusedAt = -60_000L
        /** 128 random bits, URL-safe so automation apps take it as plain text. */
        fun newKey(): String = java.util.Base64.getUrlEncoder().withoutPadding().encodeToString(ByteArray(16).also(java.security.SecureRandom()::nextBytes))
        /** Constant time; no key, stored or sent, ever matches. */
        fun authorized(expected: String, given: String?) = expected.isNotEmpty() && !given.isNullOrEmpty() &&
            java.security.MessageDigest.isEqual(expected.toByteArray(Charsets.UTF_8), given.toByteArray(Charsets.UTF_8))
        // An app may send these in a loop; a line a minute shows that it does.
        private fun refused() {
            val now = SystemClock.elapsedRealtime()
            if (now - refusedAt >= 60_000) { refusedAt = now; android.util.Log.i("Elarni", "Ignored a control broadcast without the current key") }
        }
    }
}

/** The home screen widget: state, server, speed while connected, and one button. */
class ConnectionWidget : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val result = goAsync(); val app = context.applicationContext as ElarniApplication
        Widgets.present = true
        app.repository.scope.launch { try { app.repository.awaitReady(); Widgets.refresh(app, app.repository.state.value) } finally { result.finish() } }
    }
    override fun onDeleted(context: Context, ids: IntArray) { Widgets.present = null }
    override fun onDisabled(context: Context) { Widgets.present = false }
}

/** The widget's button; the widget opens the app itself when it knows connecting needs it. */
class WidgetToggle : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync(); val app = context.applicationContext as ElarniApplication
        app.repository.scope.launch {
            // Consent can be lost after the widget drew its button.
            try { if (!app.control(ACTION_TOGGLE)) { app.startActivity(openConnect(app)); Widgets.refresh(app, app.repository.state.value) } }
            finally { result.finish() }
        }
    }
}

object Widgets {
    private var sample: LongArray? = null
    private var speed: String? = null
    private fun ids(context: Context) = AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context, ConnectionWidget::class.java))
    /** Whether a widget exists; the ids are a system call, so the provider's callbacks keep this instead (null: read again). */
    @Volatile var present: Boolean? = null
    /** Whether a widget may be in view, so reading the traffic counters is worth it (the 2 s tick asks). */
    fun shown(context: Context) = (present ?: ids(context).isNotEmpty().also { present = it }) &&
        context.getSystemService(PowerManager::class.java).isInteractive
    @Synchronized fun traffic(app: ElarniApplication, metrics: JSONObject, state: AppState) {
        val now = longArrayOf(SystemClock.elapsedRealtime(), metrics.optLong("downlinkBytes"), metrics.optLong("uplinkBytes"))
        sample?.let { last ->
            // The core counts from its start; a lower count is a new start, not negative traffic.
            fun rate(index: Int) = bytes((now[index] - last[index]).coerceAtLeast(0) * 1000 / (now[0] - last[0]).coerceAtLeast(1))
            speed = tr(R.string.traffic_rates, rate(1), rate(2))
        }
        sample = now
        refresh(app, state)
    }
    @Synchronized fun refresh(app: ElarniApplication, state: AppState) {
        if (state.connection != "connected") { sample = null; speed = null }
        // Connection transactions publish through here; a widget failure must not fail them.
        runCatching { ids(app).takeIf { it.isNotEmpty() }?.let { AppWidgetManager.getInstance(app).updateAppWidget(it, views(app, state)) } }
    }
    private fun views(app: ElarniApplication, state: AppState) = RemoteViews(app.packageName, R.layout.widget_connection).apply {
        val catalog = Catalog(state.catalog)
        val server = catalog.selectedName
        val running = state.connection in active
        setTextViewText(R.id.widget_status, if (server == null && !running) tr(R.string.choose_a_server_in_elarni) else statusLabel(state.connection, state.liveness))
        setTextViewText(R.id.widget_server, server.orEmpty())
        setViewVisibility(R.id.widget_server, if (server == null) View.GONE else View.VISIBLE)
        val shown = speed.takeIf { state.connection == "connected" }
        setTextViewText(R.id.widget_speed, shown.orEmpty())
        setViewVisibility(R.id.widget_speed, if (shown == null) View.GONE else View.VISIBLE)
        setTextViewText(R.id.widget_button, when { running -> if (state.connection == "connected") tr(R.string.disconnect) else tr(R.string.stop); server == null -> tr(R.string.open); else -> tr(R.string.connect) })
        setOnClickPendingIntent(R.id.widget_button, if (running || connectsWithoutApp(app, catalog)) PendingIntent.getBroadcast(app, 5, Intent(app, WidgetToggle::class.java), PENDING)
            else PendingIntent.getActivity(app, 6, openConnect(app), PENDING))
        setOnClickPendingIntent(R.id.widget_root, app.openApp())
    }
}
