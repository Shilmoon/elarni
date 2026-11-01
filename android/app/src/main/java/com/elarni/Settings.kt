package com.elarni

import android.net.InetAddresses
import org.json.JSONArray
import org.json.JSONObject
import java.math.BigInteger
import java.net.Inet4Address
import java.net.InetAddress

data class SettingField(val key: String, val title: String, val initial: Any,
    val section: String, val choices: List<String> = emptyList(), val detail: String = "")

object Settings {
    val logLevels = listOf("none", "error", "warning", "info", "debug")
    /** A section's name in the interface language; [SettingField.section] stays the English key. */
    fun sectionTitle(section: String) = when (section) {
        "General" -> tr(R.string.section_general); "Appearance" -> tr(R.string.section_appearance)
        "Connection" -> tr(R.string.section_connection); "Apps & routes" -> tr(R.string.section_apps_routes)
        "Advanced" -> tr(R.string.section_advanced); "Server tests" -> tr(R.string.section_server_tests)
        else -> section
    }
    // A getter, so titles follow the current language.
    val fields get() = listOfNotNull(
        SettingField("theme", tr(R.string.theme), "system", "Appearance", listOf("system", "light", "dark")),
        SettingField("accent", tr(R.string.accent), "evergreen", "Appearance", listOf("evergreen", "blue", "teal", "purple", "orange")),
        SettingField("sort", tr(R.string.server_order), "provider", "General", listOf("provider", "alphabet", "latency")),
        SettingField("favoritesFirst", tr(R.string.favorites_first), true, "General"),
        SettingField("expiryReminders", tr(R.string.subscription_expiry_reminders), false, "General"),
        SettingField("xrayTunEnabled", tr(R.string.system_vpn), true, "Connection", detail = tr(R.string.route_device_traffic_through_android_vpn)),
        SettingField("onDemandEnabled", tr(R.string.reconnect_automatically), false, "General"),
        SettingField("launchAtBoot", tr(R.string.connect_after_device_restart), false, "Connection", detail = tr(R.string.requires_prior_vpn_consent_unlock_the)),
        SettingField("disconnectOnSleep", tr(R.string.pause_when_screen_turns_off), false, "General"),
        SettingField("connectOnUntrustedWiFi", tr(R.string.connect_on_untrusted_wi_fi), false, "General",
            detail = tr(R.string.joining_a_wi_fi_network_that)),
        SettingField("resolveServer", tr(R.string.resolve_server_before_connecting), false, "DNS"),
        SettingField("preferredIP", tr(R.string.preferred_ip), "ipv4", "Connection", listOf("automatic", "ipv4", "ipv6")),
        SettingField("profilePreferredIP", tr(R.string.profile_ip_override), "inherit", "Connection", listOf("inherit", "automatic", "ipv4", "ipv6")),
        SettingField("socksPort", tr(R.string.socks_port), 10890, "Connection"),
        SettingField("httpInboundEnabled", tr(R.string.http_proxy), false, "Connection"),
        SettingField("httpPort", tr(R.string.http_port), 10891, "Connection"),
        SettingField("allowLAN", tr(R.string.allow_lan_clients), false, "Connection", detail = tr(R.string.requires_inbound_authentication_hotspot_traffic_is)),
        SettingField("inboundAuthEnabled", tr(R.string.allow_apps_without_a_login_2), false, "Connection", detail = tr(R.string.in_local_proxy_mode_any_app_2)),
        SettingField("subscriptionAutoUpdateHours", tr(R.string.refresh_interval), 4, "General", detail = tr(R.string.t_1_168_hours_background_work_follows)),
        SettingField("updateFeedURL", tr(R.string.update_feed), if (BuildConfig.DEBUG) "" else UpdateCheck.ELARNI_RELEASES, "General", detail = tr(R.string.leave_empty_to_turn_the_check)),
        SettingField("allowExternalControl", tr(R.string.let_other_apps_control_the_connection), false, "General", detail = tr(R.string.automation_apps_such_as_tasker_can)),
        SettingField("useDNSFromJSON", tr(R.string.use_profile_dns), true, "DNS"),
        SettingField("profileDNSMode", tr(R.string.dns_override), "inherit", "DNS", listOf("inherit", "default", "routing")),
        SettingField("bootstrapDNS", tr(R.string.bootstrap_dns_server), "1.1.1.1", "DNS", detail = tr(R.string.numeric_ipv4_or_ipv6_address_used)),
        SettingField("sniffingEnabled", tr(R.string.traffic_sniffing), true, "Advanced"),
        SettingField("fragmentationEnabled", tr(R.string.tls_fragmentation), false, "Advanced"),
        SettingField("fragmentPackets", tr(R.string.packets_to_fragment), "tlshello", "Advanced"),
        SettingField("fragmentLength", tr(R.string.fragment_length), "100-200", "Advanced"),
        SettingField("fragmentInterval", tr(R.string.fragment_interval), "0-1", "Advanced"),
        SettingField("muxEnabled", tr(R.string.multiplexing), false, "Advanced"),
        SettingField("memoryLimitMB", tr(R.string.memory_budget_mb_0_automatic), 0, "Advanced"),
        SettingField("idleTimeoutSeconds", tr(R.string.idle_timeout_seconds), 300, "Advanced"),
        SettingField("tcpMaxConnections", tr(R.string.maximum_tcp_sessions), 2048, "Advanced"),
        SettingField("udpMaxConnections", tr(R.string.maximum_udp_sessions), 1024, "Advanced"),
        SettingField("monitoringEnabled", tr(R.string.live_traffic_monitoring), false, "Advanced"),
        if (BuildConfig.ELARNI_RECORDING) SettingField("recordDiagnostics", tr(R.string.record_connection_diagnostics), false, "Advanced", detail = tr(R.string.records_connection_timing_byte_counts_and)) else null,
        // Chosen on the Logs screen, not in a settings section.
        SettingField("logLevel", tr(R.string.log_level), "warning", "Logs", logLevels),
        SettingField("includeAllNetworks", tr(R.string.capture_all_ip_routes), false, "Apps & routes", detail = tr(R.string.overrides_the_included_route_list_excluded)),
        SettingField("probeMode", tr(R.string.test_type), "proxy", "Server tests", listOf("proxy", "activeProxy", "tcp", "icmp")),
        SettingField("probeTimeout", tr(R.string.timeout_in_seconds_1_15), 5, "Server tests"),
        SettingField("probeMethod", tr(R.string.http_method), "GET", "Server tests", listOf("GET", "HEAD")),
        SettingField("probeVariant", tr(R.string.test_mode), "default", "Server tests", listOf("default", "double", "keepalive")),
        SettingField("probeURL", tr(R.string.test_url), "https://www.gstatic.com/generate_204", "Server tests"),
        SettingField("probeExpectedStatus", tr(R.string.expected_http_status), 204, "Server tests"),
        SettingField("probeExpectedBody", tr(R.string.expected_response_body), "", "Server tests"),
    )
    // The running core does not read these, so changing one keeps every connection.
    private val preferenceKeys = setOf("theme", "accent", "sort", "favoritesFirst", "expiryReminders", "subscriptionAutoUpdateHours",
        "onDemandEnabled", "disconnectOnSleep", "monitoringEnabled", "launchAtBoot", "logLevel", "updateFeedURL", "allowExternalControl",
        "connectOnUntrustedWiFi", "trustedWiFiNetworks") + fields.filter { it.section == "Server tests" }.map { it.key }
    fun runtime(value: JSONObject) = value.copy().apply { preferenceKeys.forEach(::remove) }
    fun probeArgs(value: JSONObject, ids: List<String>) = obj("ids" to JSONArray(ids),
        "protocol" to value.string("probeMode", "proxy"), "timeout" to value.optInt("probeTimeout", 5),
        "url" to value.string("probeURL", "https://www.gstatic.com/generate_204"), "method" to value.string("probeMethod", "GET"),
        "mode" to value.string("probeVariant", "default"), "expectedStatus" to value.optInt("probeExpectedStatus", 204), "expectedBody" to value.string("probeExpectedBody"))
    const val EXIT_TRACE_URL = "https://cp.cloudflare.com/cdn-cgi/trace"
    /** Instrumentation points it at a local fixture. */
    @Volatile var exitTraceURL = EXIT_TRACE_URL
    // Check exit reads Cloudflare's trace through the server, on the host health checks already use.
    fun exitArgs(id: String) = obj("id" to id, "protocol" to "proxy", "timeout" to 5, "url" to exitTraceURL, "method" to "GET",
        "mode" to "default", "expectedStatus" to 200, "expectedBody" to "", "trace" to true)
    fun defaults() = JSONObject().apply {
        put("schemaVersion", 1)
        fields.forEach { put(it.key, it.initial) }
        put("perAppMode", "off"); put("perAppProcesses", JSONArray()); put("perAppTargets", JSONObject())
        put("includedRoutes", JSONArray(listOf("0.0.0.0/0", "::/0")))
        put("excludedRoutes", JSONArray())
        put("trustedWiFiNetworks", JSONArray())
    }
    fun normalize(raw: JSONObject, credentials: JSONObject?): JSONObject {
        val value = defaults().merge(raw)
        if (value.opt("schemaVersion") != 1) throw AppFailure("invalid_settings")
        fields.forEach { field ->
            val item = value.get(field.key)
            if (field.initial is Boolean && item !is Boolean || field.initial is Int && item !is Int ||
                field.initial is String && item !is String || field.choices.isNotEmpty() && item !in field.choices) throw AppFailure("invalid_settings")
        }
        fun range(key: String, lower: Int, upper: Int) {
            if (value.getInt(key) !in lower..upper) throw AppFailure("invalid_settings")
        }
        range("socksPort", 1, 65535); range("httpPort", 1, 65535)
        range("subscriptionAutoUpdateHours", 1, 168); range("idleTimeoutSeconds", 30, 3600)
        range("tcpMaxConnections", 1, 4096); range("udpMaxConnections", 1, 4096)
        range("probeTimeout", 1, 15); range("probeExpectedStatus", 200, 299)
        val probeURL = value.getString("probeURL")
        val probeURI = runCatching { java.net.URI(probeURL) }.getOrNull()
        if (Catalog.safeURL(probeURL) == null || probeURL.toByteArray().size > 4096 || probeURL.any { it.code <= 32 || it.code == 127 } ||
            probeURI == null || probeURI.port != -1 && probeURI.port !in 1..65535 || value.getString("probeExpectedBody").toByteArray().size > 4096 ||
            value.getString("probeMethod") == "HEAD" && value.getString("probeExpectedBody").isNotEmpty()) throw AppFailure("invalid_settings")
        if (value.getInt("socksPort") == value.getInt("httpPort") || (value.getInt("memoryLimitMB") != 0 && value.getInt("memoryLimitMB") !in 40..4096)) throw AppFailure("invalid_settings")
        if (value.getBoolean("allowLAN") && !value.getBoolean("inboundAuthEnabled") || value.getBoolean("inboundAuthEnabled") && credentials == null) throw AppFailure("inbound_credentials_required")
        fun validRange(text: String, min: Int, max: Int): Boolean {
            if (!Regex("^[0-9]{1,5}(-[0-9]{1,5})?$").matches(text)) return false
            val parts = text.split('-').map(String::toInt)
            return parts.first() >= min && parts.first() <= parts.last() && parts.last() <= max
        }
        if (value.getString("fragmentPackets") != "tlshello" && !validRange(value.getString("fragmentPackets"), 1, 65535) ||
            !validRange(value.getString("fragmentLength"), 1, 65535) || !validRange(value.getString("fragmentInterval"), 0, 1000)) throw AppFailure("invalid_settings")
        numericAddress(value.getString("bootstrapDNS"))
        value.getString("updateFeedURL").let { if (it.isNotEmpty() && !UpdateCheck.isHttps(it)) throw AppFailure("invalid_update_feed") }
        // Up to 64 names of 1-32 bytes without control characters, as Wi-Fi allows.
        val trusted = value.optJSONArray("trustedWiFiNetworks") ?: throw AppFailure("invalid_trusted_wifi")
        if (trusted.length() > 64 || (0 until trusted.length()).any { index -> (trusted.get(index) as? String)
                ?.let { it.isEmpty() || it.toByteArray().size > 32 || it.any { char -> char.code < 32 || char.code == 127 } } ?: true }) throw AppFailure("invalid_trusted_wifi")
        for (key in listOf("includedRoutes", "excludedRoutes")) {
            val input = value.optJSONArray(key) ?: throw AppFailure("invalid_settings")
            if ((0 until input.length()).any { input.get(it) !is String }) throw AppFailure("invalid_settings")
            val routes = value.strings(key)
            if (routes.size > 64 || key == "includedRoutes" && routes.isEmpty()) throw AppFailure("invalid_settings")
            value.put(key, JSONArray(routes.map { Cidr.parse(it).toString() }.distinct()))
        }
        val mode = value.opt("perAppMode") as? String ?: throw AppFailure("invalid_per_app")
        val input = value.optJSONArray("perAppProcesses") ?: throw AppFailure("invalid_per_app")
        if ((0 until input.length()).any { input.get(it) !is String }) throw AppFailure("invalid_per_app")
        val apps = value.strings("perAppProcesses")
        if (mode !in listOf("off", "bypass", "proxyOnly") || apps.size > 256 ||
            apps.any { it.toByteArray().size > 1024 || !Regex("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z0-9_]+)+$").matches(it) } ||
            mode != "off" && (!value.getBoolean("xrayTunEnabled") || apps.isEmpty())) throw AppFailure("invalid_per_app")
        // A listed app's own target: direct, routing, block, node:<server ID> or proxy:<URL>. Apps without one take the mode's.
        val targets = value.opt("perAppTargets") as? JSONObject ?: throw AppFailure("invalid_per_app")
        if (targets.keys().asSequence().any { app -> app !in apps || when (val target = targets.get(app)) {
                "direct", "routing", "block" -> false
                is String -> !(target.startsWith("node:") && target.length in 6..133 || target.startsWith("proxy:") && perAppProxyError(target.substring(6), value) == null)
                else -> true
            } }) throw AppFailure("invalid_per_app")
        return value
    }
    /** Why a per-app proxy target is refused, or null. The core takes SOCKS5 or HTTP on this device without a login. */
    fun perAppProxyError(text: String, settings: JSONObject): String? {
        val uri = runCatching { java.net.URI(text.trim()) }.getOrNull()
        val scheme = uri?.scheme?.lowercase()
        if (uri == null || scheme !in setOf("socks", "socks5", "http")) return tr(R.string.use_a_socks5_or_http_address)
        val host = uri.host?.lowercase()?.removeSurrounding("[", "]")
        if (host != "localhost" && !(host != null && runCatching { InetAddresses.parseNumericAddress(host).isLoopbackAddress }.getOrDefault(false))) return tr(R.string.use_a_proxy_on_this_device)
        // HTTP defaults to port 80; SOCKS has no default.
        val port = if (uri.port == -1 && scheme == "http") 80 else uri.port
        if (port !in 1..65535) return tr(R.string.add_the_proxy_port_such_as)
        if (uri.rawUserInfo != null || uri.rawPath !in setOf("", "/") || uri.rawQuery != null || uri.rawFragment != null) return tr(R.string.use_only_the_address_and_port)
        if (port == settings.getInt("socksPort") || settings.getBoolean("httpInboundEnabled") && port == settings.getInt("httpPort")) return tr(R.string.that_is_elarni_s_own_proxy)
        return null
    }
    fun perAppProfile(text: String): JSONObject {
        if (text.toByteArray().size > 512 * 1024) throw AppFailure("input_too_large")
        return try {
            val value = JSONObject(text)
            val targets = value.opt("targets")
            if (value.length() != (if (value.opt("version") == 2) 6 else 5) || value.opt("format") != "elarni-per-app" || value.opt("version") !in listOf(1, 2) ||
                value.opt("platform") != "android" || value.opt("mode") !is String || value.opt("processes") !is JSONArray ||
                value.opt("version") == 2 && (targets !is JSONObject || targets.keys().asSequence().any { targets.opt(it).let { target -> target !is String || target.startsWith("node:") } })) throw AppFailure("invalid_per_app")
            normalize(defaults().put("perAppMode", value.get("mode")).put("perAppProcesses", value.get("processes")).put("perAppTargets", targets ?: JSONObject()), null)
            value
        } catch (_: Exception) { throw AppFailure("invalid_per_app") }
    }
    /** A per-app profile. Server targets name servers of this device's catalog, so they stay out. */
    fun perAppExport(mode: String, processes: List<String>, targets: JSONObject): String {
        val shared = JSONObject().apply { targets.keys().forEach { if (!targets.getString(it).startsWith("node:")) put(it, targets.getString(it)) } }
        // Without targets the profile keeps the format older versions read.
        return obj("format" to "elarni-per-app", "version" to if (shared.length() == 0) 1 else 2, "platform" to "android", "mode" to mode, "processes" to JSONArray(processes))
            .apply { if (shared.length() > 0) put("targets", shared) }.toString(2)
    }
    fun numericAddress(text: String): InetAddress {
        if (text.isBlank() || !Regex("^[0-9a-fA-F:.]+$").matches(text)) throw AppFailure("invalid_settings")
        // Hex-only names such as abc.de pass the filter; getByName would resolve them instead of failing.
        return try { InetAddresses.parseNumericAddress(text) } catch (_: Exception) { throw AppFailure("invalid_settings") }
    }
}

/** CIDR subtraction gives API 30 the same excluded-route behavior as API 33+. */
data class Cidr(val address: BigInteger, val bits: Int, val width: Int) {
    private val end get() = address + BigInteger.ONE.shiftLeft(width - bits) - BigInteger.ONE
    fun subtract(other: Cidr): List<Cidr> {
        if (width != other.width || end < other.address || other.end < address) return listOf(this)
        if (other.address <= address && other.end >= end) return emptyList()
        val next = bits + 1
        return Cidr(address, next, width).subtract(other) +
            Cidr(address + BigInteger.ONE.shiftLeft(width - next), next, width).subtract(other)
    }
    fun inet(): InetAddress {
        val output = ByteArray(width / 8)
        val bytes = address.toByteArray()
        val count = minOf(bytes.size, output.size)
        bytes.copyInto(output, output.size - count, bytes.size - count)
        return InetAddress.getByAddress(output)
    }
    override fun toString() = "${inet().hostAddress}/$bits"
    companion object {
        fun parse(text: String): Cidr {
            val pair = text.trim().split('/')
            if (pair.size != 2) throw AppFailure("invalid_settings")
            val address = Settings.numericAddress(pair[0]).address
            val width = address.size * 8
            val bits = pair[1].toIntOrNull() ?: throw AppFailure("invalid_settings")
            if (bits !in 0..width) throw AppFailure("invalid_settings")
            val value = BigInteger(1, address).shiftRight(width-bits).shiftLeft(width-bits)
            return Cidr(value, bits, width)
        }
        fun routes(settings: JSONObject): List<Cidr> {
            var routes = (if (settings.optBoolean("includeAllNetworks")) listOf("0.0.0.0/0", "::/0") else settings.strings("includedRoutes")).map(::parse)
            settings.strings("excludedRoutes").map(::parse).forEach { exclude ->
                routes = routes.flatMap { it.subtract(exclude) }
                if (routes.size > 4096) throw AppFailure("invalid_settings")
            }
            // VpnService rejects loopback and IPv4-mapped prefixes, and no traffic reaches the VPN through them.
            routes = routes.filterNot { route -> route.inet().let { it.isLoopbackAddress || route.width == 128 && it is Inet4Address } }
            if (routes.isEmpty()) throw AppFailure("invalid_settings")
            return routes.distinct()
        }
    }
}
