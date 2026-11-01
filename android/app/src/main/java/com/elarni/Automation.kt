package com.elarni

import android.os.SystemClock
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/** Monotonic recovery episodes match the desktop policy, independent of Activity lifetime. */
class Automation(saved: JSONObject) {
    var intent = false
    var online = false
    var sleeping = false
    var attempts = saved.optInt("attempts")
    var exhausted = saved.optBoolean("exhausted") || saved.optBoolean("interrupted") || attempts > 0
    var failures = 0
    var status = "disabled"
    var path = ""
    var episodeStarted: Double? = null
    var retryAt: Double? = null
    var healthAt: Double? = null
    var lastSwitch = -1000.0
    var lastOptimization = -1000.0
    private var rearmAt: Double? = null
    // Exhausted episodes since the last passing check or user action.
    private var exhaustions = 0
    private var rotation = 0
    val cooldown = mutableMapOf<String, Double>()
    val invalid = mutableSetOf<String>()
    // Mobile whitelists pass Russian addresses only: set when a Russian-entry
    // server passes after two foreign-entry ones failed, cleared by a foreign pass.
    var whitelist = false
    private val foreignFailures = mutableSetOf<String>()
    fun observe(id: String, passed: Boolean, russianEntry: Boolean) {
        if (!russianEntry) { if (passed) { whitelist = false; foreignFailures.clear() } else foreignFailures.add(id) }
        else if (passed && foreignFailures.size >= 2) whitelist = true
    }
    /** Russian entries first in whitelist mode, then TCP 443 servers when the failing one is not; otherwise the user's order. */
    fun recoveryOrder(order: List<String>, current: String, tcp443: Set<String>, russianEntry: Set<String>): List<String> {
        fun rank(id: String) = (if (whitelist && id !in russianEntry) 2 else 0) + (if (current !in tcp443 && id !in tcp443) 1 else 0)
        return (0..3).flatMap { value -> order.filter { rank(it) == value } }
    }
    fun episode() = obj("attempts" to attempts, "exhausted" to exhausted, "interrupted" to (retryAt != null || attempts > 0))
    fun rearm(time: Double) {
        rearmAt = null; attempts = 0; failures = 0; exhausted = false; exhaustions = 0
        episodeStarted = null; retryAt = null; healthAt = time; lastOptimization = -1000.0
    }
    fun stop() { intent = false; rearm(0.0); healthAt = null; status = "stopped" }
    fun path(signature: String, available: Boolean, time: Double) {
        if (signature == path && available == online) return
        val initial = path.isEmpty(); path = signature; online = available
        healthAt = null; failures = 0; lastOptimization = -1000.0
        if (available && !exhausted) {
            if (!initial && attempts == 0) rearm(time) else healthAt = time
        }
    }
    fun unattended(time: Double) {
        if (!intent || !exhausted || !online || sleeping) { rearmAt = null; return }
        // TSPU freezes an SNI for about 120 s after a burst of handshakes, so
        // each unattended episode starts past that, and later ones wait longer.
        if (rearmAt == null) rearmAt = time + listOf(150, 300, 600)[minOf(exhaustions, 2)]
        if (time >= rearmAt!!) { val count = exhaustions + 1; rearm(time); exhaustions = count }
    }
    fun healthy(time: Double) {
        attempts = 0; failures = 0; exhausted = false; exhaustions = 0; episodeStarted = null; retryAt = null
        healthAt = time + healthInterval; status = "healthy"
    }
    fun schedule(time: Double) {
        if (retryAt != null || exhausted || !online || sleeping || !intent) return
        if (episodeStarted == null) episodeStarted = time
        val delays = listOf(1, 2, 4, 8, 16, 30)
        if (attempts >= delays.size || time + delays[attempts] >= episodeStarted!! + 120) {
            exhausted = true; healthAt = null; status = "exhausted"; return
        }
        retryAt = time + delays[attempts]; healthAt = null; status = "retrying"
    }
    fun begin(time: Double): Boolean {
        if (!intent || !online || sleeping || exhausted || retryAt == null || time < retryAt!!) return false
        retryAt = null
        if (attempts >= 6 || time >= (episodeStarted ?: time) + 120) { exhausted = true; status = "exhausted"; return false }
        attempts++; return true
    }
    fun round(order: List<String>, current: String, time: Double): List<String> {
        val eligible = order.filter { it !in invalid && (cooldown[it] ?: 0.0) <= time }
        val rest = eligible.filter { it != current }
        val offset = if (rest.isEmpty()) 0 else rotation % rest.size
        val output = (eligible.filter { it == current } + rest.drop(offset) + rest.take(offset)).take(10)
        if (rest.isNotEmpty()) rotation = (offset + output.count { it != current }) % rest.size
        return output
    }
    fun choose(policy: String, order: List<String>, current: String, scores: Map<String, Double>, healthy: Boolean, time: Double): String? {
        val eligible = order.filter { scores.containsKey(it) && (healthy || it != current) }
        if (policy == "fixed") return current.takeIf { it in eligible }
        if (policy == "orderedFallback") return if (healthy && current in eligible) current else eligible.firstOrNull()
        val best = eligible.minWithOrNull(compareBy<String> { scores[it]!! }.thenBy { it != current }) ?: return null
        if (healthy && best != current) {
            val old = scores[current] ?: return current
            if (time - lastSwitch < 60 || old - scores[best]!! < 20 || old - scores[best]!! < old * 0.2) return current
        }
        return best
    }
    companion object {
        /** Seconds between health probes; instrumentation shortens it instead of waiting out production timing. */
        @Volatile var healthInterval = 30.0
        /** Seconds between liveness checks while traffic stalls or the last one failed; instrumentation shortens it. */
        @Volatile var livenessInterval = 60.0
        val defaultTargets: JSONArray get() = JSONArray(listOf(
            obj("id" to "gstatic", "url" to "https://www.gstatic.com/generate_204", "expectedStatus" to 204, "expectedBody" to ""),
            obj("id" to "cloudflare", "url" to "https://cp.cloudflare.com/generate_204", "expectedStatus" to 204, "expectedBody" to "")))
        /** Liveness targets when failover names none; instrumentation points them at its fixture. */
        @Volatile var livenessTargets: JSONArray = defaultTargets
        fun clock() = SystemClock.elapsedRealtime() / 1000.0
        /** DPI cuts UDP transports and unusual ports first; TCP 443 looks like HTTPS. */
        fun tcp443(config: JSONObject) = runCatching {
            val outbound = config.objects("outbounds").first()
            val settings = outbound.mapObject("settings"); val stream = outbound.mapObject("streamSettings")
            val server = (settings.optJSONArray("vnext") ?: settings.optJSONArray("servers"))?.optJSONObject(0)
            outbound.string("protocol") !in listOf("hysteria", "tuic", "wireguard", "amneziawg") &&
                stream.string("network") !in listOf("kcp", "mkcp", "quic", "hysteria") &&
                stream.mapObject("tlsSettings").strings("alpn") != listOf("h3") && (server ?: settings).opt("port")?.toString() == "443"
        }.getOrDefault(false)
        fun defaults() = obj("schemaVersion" to 1, "enabled" to false, "policy" to "fixed", "subscriptionID" to "", "nodeIDs" to JSONArray(), "targets" to JSONArray())
        fun validate(value: JSONObject, catalog: Catalog) {
            try {
                val ids = value.strings("nodeIDs"); val targets = value.objects("targets"); val enabled = value.getBoolean("enabled")
                require(value.getInt("schemaVersion") == 1 && value.get("enabled") is Boolean)
                require(value.getString("policy") in listOf("fixed", "lowestLatency", "orderedFallback"))
                require(value.getString("subscriptionID").length <= 128 && ids.size <= 1000 && ids.distinct().size == ids.size && ids.all { it.length in 1..128 })
                require(targets.size <= 2 && targets.map { it.getString("id") }.distinct().size == targets.size)
                val hosts = mutableSetOf<String>()
                targets.forEach {
                    val url = it.getString("url"); val uri = URI(url)
                    require(Regex("^[A-Za-z0-9._-]{1,64}$").matches(it.getString("id")))
                    require(Catalog.safeURL(url) != null && url.toByteArray().size <= 4096 && url.none { c -> c.code <= 32 || c.code == 127 })
                    require(uri.port == -1 || uri.port in 1..65535)
                    require(it.getInt("expectedStatus") in 200..299 && it.getString("expectedBody").toByteArray().size <= 4096)
                    require(hosts.add(uri.host.lowercase().trimEnd('.')))
                }
                // Backups may come from any subscription; subscriptionID names the selected server's.
                require(value.opt("russianEntryNodeIDs").let { it == null || it is JSONArray } && value.strings("russianEntryNodeIDs").all(ids::contains))
                if (enabled) {
                    require(ids.isNotEmpty() && targets.isNotEmpty() && catalog.selected in ids)
                    require(ids.all { id -> catalog.nodes.any { it.string("id") == id && it.string("format") == "xrayProfile" } })
                }
            } catch (_: Exception) { throw AppFailure("invalid_automation") }
        }
    }
}
