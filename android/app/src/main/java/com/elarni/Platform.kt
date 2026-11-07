package com.elarni

import android.app.AlarmManager
import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.SystemClock
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.system.OsConstants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import libXray.DialerController
import libXray.LibXray
import libXray.ProcessFinder
import org.json.JSONObject
import java.net.InetSocketAddress

class ElarniApplication : Application() {
    lateinit var repository: Repository
        private set
    @Volatile var vpnOwner: ElarniVpnService? = null
    @Volatile var requiresProtection = false
    /** Whether the process before this one died while its VPN service existed. */
    var serviceHeld = false
        private set
    private val serviceMarker get() = java.io.File(noBackupFilesDir, "service-running")
    val socketController = DialerController { fd ->
        !requiresProtection || fd in 0..Int.MAX_VALUE.toLong() && vpnOwner?.protect(fd.toInt()) == true
    }
    override fun onCreate() {
        super.onCreate()
        instance = this
        // Before any component starts: a marker the service did not remove outlived its process, and so did its alarm.
        serviceHeld = serviceMarker.exists()
        watchService(false)
        val notifications = getSystemService(NotificationManager::class.java)
        notifications.createNotificationChannel(NotificationChannel(CONNECTION_CHANNEL, tr(R.string.vpn_connection), NotificationManager.IMPORTANCE_LOW))
        notifications.createNotificationChannel(NotificationChannel(REVIEW_CHANNEL, tr(R.string.subscription_updates), NotificationManager.IMPORTANCE_DEFAULT))
        NativeBindings.startCore { LibXray.setAndroidSocketController(socketController) }  // the first Go call
        // A single callback delegates to the current owner. Shared-UID apps necessarily share a rule.
        LibXray.registerProcessFinder(ProcessFinder { network, source, sourcePort, destination, destinationPort ->
            if (vpnOwner == null || sourcePort !in 1..65535 || destinationPort !in 1..65535) -1L else try {
                val protocol = when (network) { "tcp" -> OsConstants.IPPROTO_TCP; "udp" -> OsConstants.IPPROTO_UDP; else -> -1 }
                if (protocol == -1) -1L else getSystemService(ConnectivityManager::class.java).getConnectionOwnerUid(protocol,
                    InetSocketAddress(Settings.numericAddress(source), sourcePort.toInt()), InetSocketAddress(Settings.numericAddress(destination), destinationPort.toInt())).toLong()
            } catch (_: Exception) { -1L }
        }, Build.VERSION.SDK_INT.toLong())
        repository = Repository(this)
        publishShortcuts()
        val connectivity = getSystemService(ConnectivityManager::class.java)
        fun changed() {
            repository.scope.launch { repository.networkChanged() }
        }
        // The default network moved or went: new sockets already leave through the new one. The core's pooled
        // connections move as well, and downloads still on the old path stop, rather than hold the repository
        // lock until they time out; server checks keep running, as a cancelled one would count as a failure.
        fun moved() {
            repository.scope.launch { Native.cancelOperations("Fetch"); LibXray.socketPathChanged(); repository.networkChanged() }
        }
        // Membership needs only these two capabilities, which the request requires, and a new default network
        // arrives as onAvailable, so capability updates such as signal strength need no pass.
        connectivity.registerNetworkCallback(NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = changed()
            override fun onLost(network: Network) = changed()
        })
        connectivity.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = moved()
            override fun onLost(network: Network) = moved()
        })
        changed()
    }
    fun openApp(): PendingIntent = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    /** Refresh intervals are an hour or more, and while the VPN service runs its 30 s maintenance pass refreshes what is due. */
    fun scheduleRefresh(needed: Boolean) {
        val scheduler = getSystemService(JobScheduler::class.java)
        val pending = scheduler.getPendingJob(REFRESH_JOB)
        // Without work the job would only start the app; scheduling the same job again stops it while it runs.
        if (!needed) { if (pending != null) scheduler.cancel(REFRESH_JOB); return }
        if (pending?.intervalMillis == REFRESH_INTERVAL) return
        scheduler.schedule(JobInfo.Builder(REFRESH_JOB, ComponentName(this, RefreshJobService::class.java))
            .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY).setPeriodic(REFRESH_INTERVAL).setPersisted(true).build())
    }
    fun refreshTile() = TileService.requestListeningState(this, ComponentName(this, ElarniTileService::class.java))
    // Android does not bring back a VPN service whose process it killed. While the service exists, a
    // non-wakeup alarm starts a killed process at the next wake, and that start reconnects.
    private val watchAlarm get() = PendingIntent.getBroadcast(this, 4, Intent(this, BootReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
    // Its own request code: an alarm set with the same PendingIntent would replace the repeating one.
    private val idleAlarm get() = PendingIntent.getBroadcast(this, 5, Intent(this, BootReceiver::class.java), PendingIntent.FLAG_IMMUTABLE)
    fun watchService(on: Boolean) {
        val alarms = getSystemService(AlarmManager::class.java)
        if (on) { runCatching { serviceMarker.createNewFile() }; alarms.setInexactRepeating(AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + 60_000, 60_000, watchAlarm); watchIdle() }
        else { alarms.cancel(watchAlarm); alarms.cancel(idleAlarm); serviceMarker.delete() }
    }
    /** Doze holds the repeating alarm for hours. While the VPN service runs and is not paused for sleep, an inexact
     *  allow-while-idle alarm (no exact-alarm permission) wakes about every 15 minutes; each alarm sets the next. */
    fun watchIdle() {
        if (!serviceMarker.exists() || repository.state.value.connection == "paused") return
        getSystemService(AlarmManager::class.java).setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, SystemClock.elapsedRealtime() + AlarmManager.INTERVAL_FIFTEEN_MINUTES, idleAlarm)
    }
    fun approvalNotification() {
        runCatching { getSystemService(NotificationManager::class.java).notify(3, Notification.Builder(this, REVIEW_CHANNEL).setSmallIcon(R.drawable.ic_elarni)
            .setContentTitle(tr(R.string.approve_download_destination)).setContentText(tr(R.string.open_elarni_to_approve_where_a)).setAutoCancel(true).setContentIntent(openApp()).build()) }
    }
    fun expiryNotification(sources: List<JSONObject>) {
        val expiring = sources.filter { it.mapObject("metadata").optDouble("expire", 0.0).let { time -> time > 0 && time < now() + 3 * 86400 } }.map { it.string("id") }.sorted()
        val manager = getSystemService(NotificationManager::class.java)
        val reminders = getSharedPreferences("reminders", MODE_PRIVATE)
        if (expiring.isEmpty()) { manager.cancel(4); reminders.edit().remove("expiry").apply(); return }
        // Maintenance runs every 30 s; a dismissed reminder returns when the set changes, or the next day.
        val key = "${(now() / 86400).toLong()}:${expiring.joinToString(",")}"
        if (reminders.getString("expiry", null) == key) return
        runCatching { manager.notify(4, Notification.Builder(this, REVIEW_CHANNEL).setSmallIcon(R.drawable.ic_elarni).setOnlyAlertOnce(true)
            .setContentTitle(tr(R.string.subscription_expiry)).setContentText(trPlural(R.plurals.expiring_subscriptions, expiring.size)).setContentIntent(openApp()).setAutoCancel(true).build()) }
        reminders.edit().putString("expiry", key).apply()
    }
    companion object {
        const val CONNECTION_CHANNEL = "connection"; const val REVIEW_CHANNEL = "updates"; const val REFRESH_JOB = 101
        const val REFRESH_INTERVAL = 60 * 60 * 1000L
        /** Set first in [onCreate], before anything asks [tr] for a string. */
        lateinit var instance: ElarniApplication
            private set
    }
}

class ElarniVpnService : VpnService() {
    private val app get() = application as ElarniApplication
    private var descriptor: ParcelFileDescriptor? = null
    private var previousDescriptor: ParcelFileDescriptor? = null
    private var tunnelInterface: String? = null
    val holdsTunnel get() = descriptor != null
    private val connectivity get() = getSystemService(ConnectivityManager::class.java)
    private val tunnelNetworks = mutableMapOf<Network, String?>()
    private val tunnelCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) { synchronized(tunnelNetworks) { tunnelNetworks[network] = null } }
        override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) {
            synchronized(tunnelNetworks) { if (tunnelNetworks.containsKey(network)) tunnelNetworks[network] = properties.interfaceName }
        }
        override fun onLost(network: Network) { synchronized(tunnelNetworks) { tunnelNetworks.remove(network) } }
    }
    private var monitor: Job? = null
    @Volatile private var finishing = false
    @Volatile private var latestStartId = 0
    private var foregroundStarted = false
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { app.repository.scope.launch { app.repository.screenChanged(intent.action == Intent.ACTION_SCREEN_OFF) } }
    }
    override fun onCreate() {
        super.onCreate()
        // The owner can observe its VPN even though its own UID is excluded.
        // Ordered callbacks arrive after Android processes the network's routes;
        // allNetworks can expose the same agent while it is still CONNECTING.
        connectivity.registerNetworkCallback(NetworkRequest.Builder()
            .removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
            .addTransportType(NetworkCapabilities.TRANSPORT_VPN).build(), tunnelCallback)
        val filter = IntentFilter(Intent.ACTION_SCREEN_OFF).apply { addAction(Intent.ACTION_SCREEN_ON) }
        if (Build.VERSION.SDK_INT >= 33) registerReceiver(screen, filter, Context.RECEIVER_NOT_EXPORTED) else registerReceiver(screen, filter)
        app.watchService(true)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        latestStartId = startId; finishing = false
        if (intent?.action == DISCONNECT) { app.repository.requestStop(); return START_NOT_STICKY }
        val vpn = app.repository.state.value.catalog.mapObject("settings").optBoolean("xrayTunEnabled", true)
        // Android starts an always-on VPN with this action, before establish(), while isAlwaysOn() still reads false.
        val alwaysOn = isAlwaysOn || intent?.action == VpnService.SERVICE_INTERFACE
        // prepare() silently moves a consented VPN to this app, so a start the user did not ask for, such as
        // the one after the system killed this process, must leave a VPN another app started meanwhile.
        val taken = vpn && intent?.action != CONNECT && !alwaysOn && connectivity.allNetworks.any { network ->
            connectivity.getNetworkCapabilities(network)?.let { it.hasTransport(NetworkCapabilities.TRANSPORT_VPN) && it.ownerUid != android.os.Process.myUid() } == true
        }
        try { foreground(vpn && !taken && prepare(this) == null) }
        catch (_: Exception) { app.repository.report(AppFailure("foreground_start_denied")); stopSelf(); return START_NOT_STICKY }
        val generation = intent?.takeIf { it.hasExtra(GENERATION) }?.getLongExtra(GENERATION, -1)
        app.repository.scope.launch { app.repository.serviceStart(this@ElarniVpnService, intent?.action != CONNECT, generation, startId, taken, alwaysOn) }
        if (monitor == null) monitor = app.repository.scope.launch {
            var ticks = 0
            while (isActive) {
                delay(2000); app.repository.tick()
                if (++ticks % 15 == 0) app.repository.maintenance()
            }
        }
        return START_STICKY
    }
    fun foreground(vpn: Boolean) {
        val notification = notification(app.repository.state.value.connection)
        if (Build.VERSION.SDK_INT >= 34) startForeground(1, notification, if (vpn) ServiceInfo.FOREGROUND_SERVICE_TYPE_SYSTEM_EXEMPTED else ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        else startForeground(1, notification)
        foregroundStarted = true
    }
    /** Whether the tunnel keeps per-app listed apps out; lockdown turned on meanwhile blocks them until the next start. */
    var splitsApps = false
        private set
    fun establishTunnel(settings: JSONObject): Int {
        if (prepare(this) != null) throw AppFailure("vpn_consent_required")
        fun interfaceNames() = java.net.NetworkInterface.getNetworkInterfaces().asSequence().map { it.name }.toSet()
        var interfaces = interfaceNames()
        var apps = Catalog.tunnelApps(settings, packageName) { runCatching { packageManager.getApplicationInfo(it, 0).uid }.getOrNull() }.takeUnless { isLockdownEnabled }
        var replacement = tunnel(settings, apps)
        // Lockdown reads false until this app's VPN exists, and it blocks every app the lists leave out.
        if (apps != null && isLockdownEnabled) {
            apps = null; interfaces = interfaceNames()
            val split = replacement
            replacement = try { tunnel(settings, null) } finally { runCatching { split.close() } }
        }
        // A failed start can keep its interface; only the newest predecessor is still needed.
        previousDescriptor?.let { runCatching { it.close() } }
        previousDescriptor = descriptor
        descriptor = replacement; splitsApps = apps != null
        tunnelInterface = java.net.NetworkInterface.getNetworkInterfaces().asSequence().firstOrNull {
            it.name !in interfaces && it.inetAddresses.asSequence().any { address -> address.hostAddress == "198.51.100.253" }
        }?.name ?: throw AppFailure("vpn_network_unavailable")
        return descriptor!!.fd
    }
    private fun tunnel(settings: JSONObject, apps: Pair<Boolean, List<String>>?): ParcelFileDescriptor {
        val builder = Builder().setSession("Elarni").setMtu(MTU).setMetered(false)
            .addAddress("198.51.100.253", 30).addAddress("fdfe:dcba:9876::1", 126)
            // Not a public resolver: automatic Private DNS would upgrade it to DNS-over-TLS, which skips the port-53 DNS route.
            .addDnsServer("198.51.100.254").addDnsServer("fdfe:dcba:9876::2")
            .setConfigureIntent(app.openApp())
        val (allowed, names) = apps ?: (false to emptyList<String>())
        // Android takes allowed or disallowed apps, never both; this app stays out either way, and an app removed meanwhile is skipped.
        if (!allowed || names.count { runCatching { builder.addAllowedApplication(it) }.isSuccess } == 0) {
            builder.addDisallowedApplication(packageName)
            if (!allowed) names.forEach { runCatching { builder.addDisallowedApplication(it) } }
        }
        Cidr.routes(settings, keepDiscovery = Build.VERSION.SDK_INT >= 29 && isLockdownEnabled).forEach { builder.addRoute(it.inet(), it.bits) }
        return builder.establish() ?: throw AppFailure("vpn_consent_required")
    }
    fun awaitTunnelReady(valid: () -> Unit) {
        val deadline = android.os.SystemClock.elapsedRealtime() + 5000
        while (android.os.SystemClock.elapsedRealtime() < deadline) {
            valid()
            // A replacement descriptor may keep the existing Network. Wait for
            // its new interface's link-properties callback, not just onAvailable.
            if (synchronized(tunnelNetworks) { tunnelInterface != null && tunnelNetworks.containsValue(tunnelInterface) }) {
                previousDescriptor?.close(); previousDescriptor = null
                return
            }
            Thread.sleep(20)
        }
        throw AppFailure("vpn_network_unavailable")
    }
    fun closeTunnel() {
        val previousInterface = tunnelInterface
        runCatching { previousDescriptor?.close() }; previousDescriptor = null
        runCatching { descriptor?.close() }; descriptor = null; tunnelInterface = null; splitsApps = false
        if (previousInterface != null) {
            // Do not publish disconnected while Android is still removing this
            // network's UID routes. A following Connect can otherwise race it.
            val deadline = android.os.SystemClock.elapsedRealtime() + 5000
            while (android.os.SystemClock.elapsedRealtime() < deadline && synchronized(tunnelNetworks) {
                tunnelNetworks.containsValue(previousInterface)
            }) Thread.sleep(20)
        }
    }
    private fun notification(state: String): Notification {
        val disconnect = PendingIntent.getService(this, 1, Intent(this, ElarniVpnService::class.java).setAction(DISCONNECT), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val vpn = app.repository.state.value.catalog.mapObject("settings").optBoolean("xrayTunEnabled", true)
        val passes = if (app.repository.state.value.liveness == "noTraffic") tr(R.string.server_passes_no_traffic) else ""
        val text = when (state) { "connected" -> (if (vpn) tr(R.string.vpn_connected) else tr(R.string.local_proxy_running)) + passes; "paused" -> tr(R.string.paused_while_screen_is_off); "failed" -> tr(R.string.connection_failed_open_to_review); "disconnecting" -> tr(R.string.disconnecting_2); "disconnected" -> tr(R.string.disconnected); else -> tr(R.string.connecting_2) }
        return Notification.Builder(this, ElarniApplication.CONNECTION_CHANNEL).setSmallIcon(R.drawable.ic_elarni).setContentTitle("Elarni").setContentText(text)
            .setOngoing(true).setOnlyAlertOnce(true).setCategory(Notification.CATEGORY_SERVICE).setContentIntent(app.openApp())
            .addAction(Notification.Action.Builder(null, tr(R.string.disconnect), disconnect).build()).build()
    }
    fun updateNotification(state: String) { if (foregroundStarted && !finishing) runCatching { getSystemService(NotificationManager::class.java).notify(1, notification(state)) } }
    fun finish(startId: Int = latestStartId) {
        if (!stopSelfResult(startId)) return
        finishing = true; foregroundStarted = false; stopForeground(STOP_FOREGROUND_REMOVE)
    }
    override fun onRevoke() { app.repository.scope.launch { app.repository.serviceGone(this@ElarniVpnService, true); finish() } }
    override fun onDestroy() {
        monitor?.cancel(); monitor = null
        unregisterReceiver(screen)
        app.watchService(false)
        app.repository.scope.launch {
            try { app.repository.serviceGone(this@ElarniVpnService, false) }
            finally { connectivity.unregisterNetworkCallback(tunnelCallback) }
        }
        super.onDestroy()
    }
    companion object {
        const val CONNECT = "com.elarni.CONNECT"; const val DISCONNECT = "com.elarni.DISCONNECT"; const val GENERATION = "generation"
        // Each TUN packet costs the userspace stack one syscall; 9000 moves bulk TCP in about 6x fewer.
        const val MTU = 9000
    }
}

class ElarniTileService : TileService() {
    private val app get() = application as ElarniApplication
    // Paused for sleep, the tunnel is down: the tile shows off with a Paused subtitle, and a tap connects.
    private val active = listOf("connected", "connecting")
    private var watch: Job? = null
    // A listening tile ignores requestListeningState, so follow the state until listening stops.
    override fun onStartListening() {
        watch?.cancel()
        watch = app.repository.scope.launch {
            app.repository.awaitReady()
            app.repository.state.map { Triple(it.connection, it.liveness, Catalog(it.catalog).selectedName) }.distinctUntilChanged().collect { (connection, liveness, server) ->
                qsTile?.let {
                    val running = connection in active
                    it.state = if (running) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
                    // While on, the tile names the server in use.
                    it.label = server?.takeIf { running } ?: "Elarni"
                    it.subtitle = statusLabel(connection, liveness); it.updateTile()
                }
            }
        }
    }
    override fun onStopListening() { watch?.cancel(); watch = null }
    // The PendingIntent overload was added in API 34. Lint does not account for
    // this guarded compatibility path; API 30–33 require the Intent overload.
    @android.annotation.SuppressLint("StartActivityAndCollapseDeprecated")
    override fun onClick() {
        super.onClick()
        val repository = app.repository
        repository.scope.launch {
            // A tap can start a cold process before the catalog has loaded.
            repository.awaitReady()
            val state = repository.state.value
            if (state.connection in active) { repository.requestStop(); return@launch }
            // VPN consent exempts this foreground-service start from Android 14+ background limits.
            if (Catalog(state.catalog).selected.isNotEmpty() && VpnService.prepare(this@ElarniTileService) == null) {
                try { repository.requestConnect() } catch (error: Exception) { if (error !is AppFailure || error.code != "cancelled") repository.report(error) }
                return@launch
            }
            // Consent and choosing a server still need the app.
            withContext(Dispatchers.Main) {
                val intent = openConnect(this@ElarniTileService)
                if (Build.VERSION.SDK_INT >= 34) startActivityAndCollapse(PendingIntent.getActivity(this@ElarniTileService, 2, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
                else @Suppress("DEPRECATION") startActivityAndCollapse(intent)
            }
        }
    }
}

class RefreshJobService : JobService() {
    private var work: Job? = null
    override fun onStartJob(params: JobParameters): Boolean {
        work = (application as ElarniApplication).repository.scope.launch {
            try { (application as ElarniApplication).repository.maintenance(wait = true) } finally { jobFinished(params, false) }
        }
        return true
    }
    override fun onStopJob(params: JobParameters): Boolean { work?.cancel(); return true }
}

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync(); val app = context.applicationContext as ElarniApplication
        // The service watch alarms carry no action: starting the process is what they do, and a live one sets the next idle alarm.
        // The repository schedules the refresh job as the process starts.
        app.repository.scope.launch {
            try { if (intent.action == Intent.ACTION_BOOT_COMPLETED) app.repository.boot() else { app.repository.awaitReady(); app.watchIdle() } }
            finally { result.finish() }
        }
    }
}
