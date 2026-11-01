package com.elarni

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.wifi.WifiInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.SystemClock
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull

/**
 * Connect on untrusted Wi-Fi: joining a Wi-Fi network that is not on the trusted list connects, once per join.
 * Android sends a network callback's PendingIntent once, for the first matching network, then drops the request,
 * so Elarni asks for one change at a time: the next Wi-Fi join while off Wi-Fi, leaving Wi-Fi while on it.
 */
object WiFiRule {
    private const val JOIN = "com.elarni.wifi.JOIN"
    private const val LEAVE = "com.elarni.wifi.LEAVE"
    private const val CHECK = "com.elarni.wifi.CHECK"
    private fun request(transport: Int, vararg capabilities: Int) = NetworkRequest.Builder().addTransportType(transport)
        .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET).addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
        .apply { capabilities.forEach { addCapability(it) } }.build()
    private val wifi get() = request(NetworkCapabilities.TRANSPORT_WIFI)
    // Mobile data runs in the background while Wi-Fi is up and turns foreground when Wi-Fi goes.
    private val leave get() = request(NetworkCapabilities.TRANSPORT_CELLULAR, NetworkCapabilities.NET_CAPABILITY_FOREGROUND)
    // Android fills in the network, so these stay mutable; each names its receiver.
    private fun wake(context: Context, action: String) = PendingIntent.getBroadcast(context, 7, Intent(context, WiFiWatch::class.java).setAction(action),
        PendingIntent.FLAG_MUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    private val lock = Mutex()
    private var retry: Job? = null
    @Volatile private var synced: Boolean? = null
    /** The change Android reports next: "join", "leave", or null while neither can be asked for. */
    @Volatile var watching: String? = null
        private set

    /** Android shows Wi-Fi names only to an app allowed to use location all the time, with location on. */
    fun namesAllowed(context: Context) = listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        .all { context.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED } &&
        context.getSystemService(LocationManager::class.java).isLocationEnabled

    /** Each process starts watching once; turning the rule on counts the current network as a new join. */
    fun sync(app: ElarniApplication, catalog: Catalog) {
        val on = catalog.settings.optBoolean("connectOnUntrustedWiFi")
        if (synced == on) return
        if (synced == false && on) app.getSharedPreferences("wifi-rule", Context.MODE_PRIVATE).edit().remove("join").apply()
        synced = on
        app.repository.scope.launch { arm(app) }
    }

    /** Handles the Wi-Fi network joined now, if any, and asks Android for the next change. */
    suspend fun arm(app: ElarniApplication, attempt: Int = 0): Unit = lock.withLock {
        app.repository.awaitReady()
        // A retry runs this itself; any other call takes its place.
        val self = currentCoroutineContext()[Job]
        retry?.takeIf { it != self }?.cancel()
        val connectivity = app.getSystemService(ConnectivityManager::class.java)
        val alarms = app.getSystemService(AlarmManager::class.java)
        fun drop(action: String) = runCatching { connectivity.unregisterNetworkCallback(wake(app, action)) }
        fun ask(action: String, request: NetworkRequest) = runCatching { connectivity.registerNetworkCallback(request, wake(app, action)) }.isSuccess
        if (!Catalog(app.repository.state.value.catalog).settings.optBoolean("connectOnUntrustedWiFi")) {
            drop(JOIN); drop(LEAVE); alarms.cancel(wake(app, CHECK)); watching = null
            return@withLock
        }
        // A backstop for the changes Android cannot report: one Wi-Fi network straight to another, or a request it refused.
        alarms.setInexactRepeating(AlarmManager.ELAPSED_REALTIME, SystemClock.elapsedRealtime() + AlarmManager.INTERVAL_FIFTEEN_MINUTES,
            AlarmManager.INTERVAL_FIFTEEN_MINUTES, wake(app, CHECK))
        @Suppress("DEPRECATION") val networks = connectivity.allNetworks.mapNotNull { network -> connectivity.getNetworkCapabilities(network)?.let { network to it } }
        val joined = networks.firstOrNull { wifi.canBeSatisfiedBy(it.second) }?.first
        if (joined == null) {
            drop(LEAVE)
            watching = if (ask(JOIN, wifi)) "join" else null
            return@withLock
        }
        drop(JOIN)
        joined(app, joined)
        if (networks.none { leave.canBeSatisfiedBy(it.second) }) watching = if (ask(LEAVE, leave)) "leave" else null
        else {
            // Mobile data stays foreground for about 30 s after Wi-Fi comes back; asking now would report at once.
            drop(LEAVE); watching = null
            if (attempt < 24) retry = app.repository.scope.launch { delay(5000); arm(app, attempt + 1) }
        }
    }

    private suspend fun joined(app: ElarniApplication, network: Network) {
        val settings = Catalog(app.repository.state.value.catalog).settings
        // Network handles repeat after a restart; the boot count tells the joins apart.
        val join = "${android.provider.Settings.Global.getInt(app.contentResolver, android.provider.Settings.Global.BOOT_COUNT, 0)}:${network.networkHandle}"
        val seen = app.getSharedPreferences("wifi-rule", Context.MODE_PRIVATE)
        if (seen.getString("join", null) == join) return
        // Without location access the name is hidden; Settings shows what to allow.
        val name = name(app, network) ?: return
        seen.edit().putString("join", join).apply()
        if (name !in settings.strings("trustedWiFiNetworks")) app.control(ACTION_CONNECT)
    }

    private suspend fun name(app: ElarniApplication, network: Network): String? {
        val ssid = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Only a callback that asks for location information sees the name; other reads get it redacted.
            val result = CompletableDeferred<String?>()
            val connectivity = app.getSystemService(ConnectivityManager::class.java)
            val callback = object : ConnectivityManager.NetworkCallback(FLAG_INCLUDE_LOCATION_INFO) {
                override fun onCapabilitiesChanged(changed: Network, capabilities: NetworkCapabilities) {
                    if (changed == network) result.complete((capabilities.transportInfo as? WifiInfo)?.ssid)
                }
                override fun onLost(lost: Network) { if (lost == network) result.complete(null) }
            }
            connectivity.registerNetworkCallback(wifi, callback)
            try { withTimeoutOrNull(5000) { result.await() } } finally { connectivity.unregisterNetworkCallback(callback) }
        } else @Suppress("DEPRECATION") app.getSystemService(WifiManager::class.java).connectionInfo
            ?.takeIf { app.getSystemService(ConnectivityManager::class.java).getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true }?.ssid
        // UTF-8 names come quoted; other bytes come as hex, which the trusted list can hold too.
        return ssid?.takeIf { it.isNotEmpty() && it != WifiManager.UNKNOWN_SSID }?.removeSurrounding("\"")
    }
}

/** Android sends this for a watched network change, at the backup check, and after an app update. */
class WiFiWatch : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val result = goAsync(); val app = context.applicationContext as ElarniApplication
        app.repository.scope.launch { try { WiFiRule.arm(app) } finally { result.finish() } }
    }
}
