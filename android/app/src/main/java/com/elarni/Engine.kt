package com.elarni

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URI
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.io.File

/** Called only by the repository actor. Native asset readers and the core share one owner. */
class Engine(private val app: ElarniApplication, private val assets: RoutingAssets) {
    companion object {
        // Android excludes this app from its own VPN; while the core runs, the app's
        // subscription and resource fetches use its SOCKS inbound to stay in the tunnel.
        @Volatile var fetchProxy: String? = null
            private set
        // VPN mode always authenticates its listeners: other apps, including ones
        // excluded from the VPN, must not proxy through them to learn the exit address.
        @Volatile private var sessionAuth: JSONObject? = null
        fun socksProxy(catalog: Catalog): String {
            val auth = if (catalog.settings.optBoolean("inboundAuthEnabled")) catalog.data.mapObject("inboundCredentials") else sessionAuth
            val user = auth?.let { it.getString("username") + ":" + it.getString("password") }
            return URI("socks5", user, "127.0.0.1", catalog.settings.getInt("socksPort"), null, null, null).toASCIIString()
        }
        private fun sessionCredentials(): JSONObject {
            val random = java.security.SecureRandom()
            fun token() = ByteArray(16).also(random::nextBytes).joinToString("") { "%02x".format(it) }
            return obj("username" to token(), "password" to token())
        }
    }
    var service: ElarniVpnService? = null
        private set
    var running = false
        private set
    /** The physical network the running core was started on. */
    var network: Network? = null
        private set
    private var activeAssets = ""
    private val dns = Executors.newFixedThreadPool(32)
    private val connectivity get() = app.getSystemService(ConnectivityManager::class.java)
    private fun isPhysical(network: Network): Boolean =
        connectivity.getNetworkCapabilities(network)?.let { it.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) && it.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) } == true
    fun physical(): Network? = connectivity.activeNetwork?.takeIf(::isPhysical) ?: connectivity.allNetworks.firstOrNull(::isPhysical)
    fun attach(owner: ElarniVpnService) { service = owner }
    fun detach(owner: ElarniVpnService) { if (service === owner) service = null }
    fun addresses(endpoint: JSONObject, settings: JSONObject, mapping: JSONObject): List<InetAddress> {
        if (mapping.optBoolean("blocked")) throw AppFailure("connection_failed")
        val host = mapping.string("alias", endpoint.getString("host"))
        val hints = if (mapping.has("addresses")) mapping.strings("addresses") else endpoint.strings("addresses")
        var values = if (hints.isNotEmpty()) hints.map(Settings::numericAddress) else {
            runCatching { Settings.numericAddress(host) }.getOrNull()?.let(::listOf) ?: run {
                val network = physical()
                val query = dns.submit<List<InetAddress>> { (network?.getAllByName(host) ?: InetAddress.getAllByName(host)).toList() }
                try { query.get(5, TimeUnit.SECONDS) } finally { query.cancel(true) }
            }
        }
        val preference = settings.string("profilePreferredIP").takeUnless { it == "inherit" } ?: settings.getString("preferredIP")
        val v4 = values.filterIsInstance<Inet4Address>(); val v6 = values.filterIsInstance<Inet6Address>()
        values = when (preference) {
            "ipv4" -> v4; "ipv6" -> v6
            else -> when (endpoint.string("domainStrategy").lowercase()) {
                "forceipv4" -> v4; "forceipv6" -> v6
                "useipv4" -> v4.ifEmpty { values }; "useipv6" -> v6.ifEmpty { values }
                "useipv4v6", "forceipv4v6" -> v4 + v6
                "useipv6v4", "forceipv6v4" -> v6 + v4
                else -> values
            }
        }
        if (values.isEmpty()) throw AppFailure("connection_failed")
        return values
    }
    private fun mappings(config: JSONObject, endpoints: List<JSONObject>) = Native.call("profileHostMappings", obj("configJSON" to config.toString(), "hosts" to JSONArray(endpoints.map { it.getString("host") }.distinct())))
    // Xray keeps a connection up to 1 s after the app closes its side, so a burst of short connections holds hundreds
    // of TLS sessions (+130 MB at 600 conn/s). Close with the app, as the mihomo clients do; a profile's own value wins.
    // The cost: an app that half-closes and then waits for a reply loses the reply.
    private fun closeWithApp(config: JSONObject) {
        val policy = config.optJSONObject("policy") ?: JSONObject().also { config.put("policy", it) }
        val levels = policy.optJSONObject("levels") ?: JSONObject().also { policy.put("levels", it) }
        val level = levels.optJSONObject("0") ?: JSONObject().also { levels.put("0", it) }
        if (!level.has("downlinkOnly")) level.put("downlinkOnly", 0)
    }
    fun prepare(catalog: Catalog, id: String, inboundAuth: JSONObject? = null): JSONObject {
        val config = catalog.compile(id, app, inboundAuth = inboundAuth)
        val endpoints = Native.domain("profileEndpoints", obj("config" to config)).objects("endpoints").filter { it.optBoolean("physical") }
        val resolved = JSONObject(); val unavailable = JSONArray(); val mappings = mappings(config, endpoints)
        val settings = catalog.settings
        catalog.node(id).string("ipPreference").takeIf { it.isNotEmpty() }?.let { settings.put("profilePreferredIP", it) }
        endpoints.forEach { endpoint ->
            try { resolved.put(endpoint.getString("addressPath"), addresses(endpoint, settings, mappings.mapObject(endpoint.getString("host"))).first().hostAddress) }
            catch (_: Exception) { unavailable.put(endpoint.getString("addressPath")) }
        }
        return try {
            Native.domain("prepareConfig", obj("config" to config, "resolved" to resolved, "unavailable" to unavailable,
                "pin" to settings.getBoolean("resolveServer"), "pinHosts" to JSONArray(mappings.keys().asSequence().toList()))).getJSONObject("config")
                .also { closeWithApp(it) }
        } catch (error: AppFailure) {
            // The profile compiled above; with servers left out, a failure means none could be reached.
            throw if (unavailable.length() > 0) AppFailure("connection_failed") else error
        }
    }
    // keepTunnel leaves a failed start's interface up, so traffic is dropped
    // instead of leaving the device while automatic recovery retries.
    fun start(catalog: Catalog, keepTunnel: Boolean = false, valid: () -> Unit) = synchronized(Native.runtimeLock) {
        val owner = service ?: throw AppFailure("service_unavailable")
        // A recording that cannot start must not block the connection.
        if (BuildConfig.ELARNI_RECORDING) runCatching { record(catalog.settings.optBoolean("recordDiagnostics")) }
        val network = physical()
        val auth = catalog.settings.takeIf { it.getBoolean("xrayTunEnabled") && !it.optBoolean("inboundAuthEnabled") }?.let { sessionCredentials() }
        val config = prepare(catalog, catalog.selected, auth)
        val directory = assets.directory(catalog.routeFor(catalog.selected)?.string("assetRevision") ?: "")
        valid()
        val setting = catalog.settings
        val vpn = setting.getBoolean("xrayTunEnabled")
        // Keep the service's old descriptor until Android hands over to the new
        // interface. Closing it first temporarily removes the app's VPN routes.
        stop(releaseTunnel = !vpn)
        try {
            owner.foreground(vpn)
            app.vpnOwner = if (vpn) owner else null
            app.requiresProtection = vpn
            LibXray.useAndroidAssets(directory)
            val dnsAddress = Settings.numericAddress(setting.getString("bootstrapDNS")).hostAddress!!
            LibXray.setDNS(app.socketController, if (dnsAddress.contains(':')) "[$dnsAddress]:53" else "$dnsAddress:53")
            LibXray.setAndroidSessionLimits(setting.getInt("tcpMaxConnections").toLong(), setting.getInt("udpMaxConnections").toLong())
            val limit = setting.getInt("memoryLimitMB").let { if (it == 0) 192 else it }
            Native.call("setMemoryLimit", obj("bytes" to limit.toLong() * 1024 * 1024))
            if (vpn) LibXray.setTunFD(owner.establishTunnel(setting).toLong())
            valid()
            Native.call("runXrayFromJson", obj("configJSON" to config.toString()))
            LibXray.setTunFD(-1)
            valid()
            if (!Native.call("getXrayState").optBoolean("running")) throw AppFailure("connection_failed")
            Socket().use { it.connect(InetSocketAddress("127.0.0.1", setting.getInt("socksPort")), 1500) }
            // establish() returns a descriptor before ConnectivityService finishes
            // installing the new VPN network and UID routes after reconfiguration.
            if (vpn) owner.awaitTunnelReady(valid)
            valid()
            activeAssets = directory; running = true; sessionAuth = auth; fetchProxy = socksProxy(catalog); this.network = network
        } catch (error: Exception) { stop(releaseTunnel = !keepTunnel); throw error }
    }
    fun stop(releaseTunnel: Boolean = true) = synchronized(Native.runtimeLock) {
        try { Native.call("stopXray") }
        finally {
            running = false; activeAssets = ""; fetchProxy = null; sessionAuth = null
            runCatching { LibXray.setTunFD(-1) }
            if (releaseTunnel) service?.closeTunnel()
            LibXray.resetDNS()
            app.requiresProtection = false; app.vpnOwner = null
            runCatching { LibXray.useAndroidAssets("") }
        }
    }
    // The connection recording runs from a start until the VPN service goes, outside backups.
    private val recording get() = File(app.noBackupFilesDir, "diagnostics")
    fun record(enabled: Boolean) {
        Native.call("diagnostics", if (enabled) obj("action" to "start", "directory" to recording.path, "role" to "provider") else obj("action" to "stop"))
    }
    fun markRecording() {
        // A session's recording lists its open connections with the mark, even while a start is still running.
        if (runCatching { Native.call("diagnostics", obj("action" to "mark")) }.isSuccess) return
        // With none, a short recording still dates a failed connect; the lock keeps a start from adopting it.
        synchronized(Native.runtimeLock) {
            record(true)
            try { Native.call("diagnostics", obj("action" to "mark")) } finally { runCatching { record(false) } }
        }
    }
    fun exportRecording(): ByteArray {
        val file = File(app.cacheDir, "recording-${System.nanoTime()}.zip")
        try {
            Native.call("diagnostics", obj("action" to "export", "directory" to recording.path, "destination" to file.path))
            return file.readBytes()
        } finally { file.delete() }
    }
    fun probe(catalog: Catalog, id: String, args: JSONObject): JSONObject {
        val method = args.string("protocol", "proxy")
        if (method !in listOf("tcp", "icmp", "proxy", "activeProxy")) throw AppFailure("unsupported_ping_method")
        val timeout = args.optInt("timeout", 5)
        // libXray admits probes of 1–15 s.
        if (timeout !in 1..15) throw AppFailure("invalid_input")
        val delay: Long
        var exit: JSONObject? = null
        if (method == "tcp" || method == "icmp") {
            val config = catalog.compile(id, app)
            val endpoint = Native.domain("profileEndpoints", obj("config" to config)).objects("endpoints").firstOrNull { it.optBoolean("physical") } ?: throw AppFailure("unsupported_ping_method")
            if (method == "tcp" && !endpoint.optBoolean("supportsTcpProbe")) throw AppFailure("unsupported_ping_method")
            val settings = catalog.settings
            catalog.node(id).string("ipPreference").takeIf { it.isNotEmpty() }?.let { settings.put("profilePreferredIP", it) }
            val address = addresses(endpoint, settings, mappings(config, listOf(endpoint)).mapObject(endpoint.getString("host"))).first()
            if (method == "tcp") {
                val start = System.nanoTime()
                Socket().use { socket -> physical()?.bindSocket(socket); socket.connect(InetSocketAddress(address, endpoint.getInt("port")), timeout * 1000) }
                delay = (System.nanoTime() - start) / 1_000_000
            } else {
                // Numeric address and fixed arguments only; the application UID bypasses its own TUN.
                val process = ProcessBuilder("/system/bin/ping", if (address is Inet6Address) "-6" else "-4", "-n", "-c", "1", "-W", timeout.toString(), address.hostAddress!!).redirectErrorStream(true).start()
                try {
                    if (!process.waitFor((timeout + 2).toLong(), TimeUnit.SECONDS) || process.exitValue() != 0) throw AppFailure("ping_failed")
                    val output = String(process.inputStream.readBounded(16384), Charsets.UTF_8)
                    delay = Regex("time[=<]([0-9.]+)").find(output)?.groupValues?.get(1)?.toDouble()?.toLong() ?: throw AppFailure("ping_failed")
                } finally { process.destroyForcibly() }
            }
        } else {
            val active = running && catalog.selected == id
            if (method == "activeProxy" && !active) throw AppFailure("not_connected")
            val request = obj("timeout" to timeout, "url" to args.string("url", "https://www.gstatic.com/generate_204"), "method" to args.string("method", "HEAD"), "mode" to args.string("mode", "default"))
            for (key in listOf("expectedStatus", "expectedBody")) if (args.has(key)) request.put(key, args.get(key))
            if (args.optBoolean("trace")) request.put("trace", true)
            if (active) {
                request.put("proxy", fetchProxy ?: throw AppFailure("not_connected"))
                    .put("configJSON", obj("inbounds" to JSONArray(), "outbounds" to JSONArray(listOf(obj("protocol" to "freedom")))).toString())
            } else {
                val port = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
                // Only settings change; 32 workers each copying a 4,096-server catalog ran out of memory.
                val probe = Catalog(JSONObject().merge(catalog.data))
                probe.data.put("settings", probe.settings.put("socksPort", port).put("httpInboundEnabled", false).put("xrayTunEnabled", false).put("perAppMode", "off").put("allowLAN", false).put("inboundAuthEnabled", false))
                // Other apps, including ones the VPN excludes, must not borrow this listener.
                val auth = sessionCredentials()
                request.put("configJSON", prepare(probe, id, auth).toString()).put("proxy", "socks5://${auth.getString("username")}:${auth.getString("password")}@127.0.0.1:$port")
                    .put("androidAssetDirectory", assets.directory(catalog.routeFor(id)?.string("assetRevision") ?: ""))
            }
            val reply = Native.cancellable("ping", request)
            delay = reply.getLong("delay")
            if (delay < 0) throw AppFailure("ping_failed")
            exit = reply.optJSONObject("exit")
        }
        return obj("nodeId" to id, "configurationRevision" to catalog.node(id).string("configurationRevision", id), "protocol" to method, "status" to "success", "latencyMs" to delay, "timestamp" to now())
            .apply { exit?.let { put("exit", it) } }
    }
}
