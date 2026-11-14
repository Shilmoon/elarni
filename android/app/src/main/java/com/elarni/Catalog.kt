package com.elarni

import android.content.Context
import android.os.Build
import android.util.Base64
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

class ResourceReview(val catalog: Catalog, val routeID: String, val url: String, val warning: JSONObject) : Exception()

/** Value catalog: every editor works on a copy; only Repository publishes it.
 *  A [snapshot] is a published copy that nothing edits, such as the one the screens read many times in a frame:
 *  it reads its lists and settings once. */
class Catalog(val data: JSONObject, private val snapshot: Boolean = false) {
    private val read = if (snapshot) java.util.concurrent.ConcurrentHashMap<String, Any>() else null
    @Suppress("UNCHECKED_CAST")
    private fun <T : Any> once(name: String, value: () -> T): T = if (read == null) value() else read.getOrPut(name, value) as T
    val sources get() = once("sources") { data.objects("subscriptions") }
    val routes get() = once("routes") { data.objects("profiles") }
    val assignments get() = data.mapObject("assignments")
    val settings get() = once("settings") { Settings.defaults().merge(data.mapObject("settings")) }
    val selected get() = data.string("selectedNodeId")
    val nodes get() = once("nodes") { sources.flatMap { it.objects("nodes") } }
    val selectedName get() = nodes.firstOrNull { it.string("id") == selected }?.string("name")
    fun copy() = Catalog(data.copy())
    fun source(id: String) = sources.firstOrNull { it.string("id") == id } ?: throw AppFailure("not_found")
    fun nodeOrNull(id: String): JSONObject? = if (read != null) once("nodeIndex") { nodes.associateBy { it.string("id") } }[id] else nodes.firstOrNull { it.string("id") == id }
    fun node(id: String) = nodeOrNull(id) ?: throw AppFailure("not_found")
    fun route(id: String) = routes.firstOrNull { it.string("id") == id } ?: throw AppFailure("not_found")
    fun sourceFor(id: String) = sources.firstOrNull { it.objects("nodes").any { node -> node.string("id") == id } } ?: throw AppFailure("not_found")
    fun routeFor(id: String): JSONObject? {
        val routeId = assignments.string(sourceFor(id).string("id"))
        return routes.firstOrNull { it.string("id") == routeId && it.optBoolean("enabled", true) }
    }
    private fun put(key: String, value: JSONObject) {
        val items = data.objects(key).toMutableList()
        val at = items.indexOfFirst { it.string("id") == value.string("id") }
        if (at < 0) items.add(value) else items[at] = value
        data.put(key, JSONArray(items))
    }
    fun putSource(value: JSONObject) = put("subscriptions", value)
    fun putRoute(value: JSONObject) = put("profiles", value)
    fun validate() {
        // Edits reach the limits; only an unreadable catalog is corrupt.
        if (sources.size > 1024 || routes.size > 256 || nodes.size > 4096) throw AppFailure("catalog_limit")
        if (data.optInt("version") != 1 || !installationPattern.matches(data.string("installationID"))) throw AppFailure("storage_corrupt")
        for (items in listOf(sources, routes, nodes)) {
            val ids = items.map { it.string("id") }
            if (ids.toSet().size != ids.size || ids.any { !idPattern.matches(it) }) throw AppFailure("storage_corrupt")
        }
        if ((sources + nodes).any { it.string("name").length > 1024 }) throw AppFailure("catalog_limit")
        sources.forEach { source ->
            if (source.has("url") && safeURL(source.string("url")) == null) throw AppFailure("storage_corrupt")
        }
        nodes.forEach {
            if (it.string("format") !in listOf("xrayProfile", "telegram") || it.optJSONObject("config") == null) throw AppFailure("storage_corrupt")
        }
        routes.forEach { if (it.optJSONObject("profile") == null || it.optJSONObject("routeModel") == null) throw AppFailure("storage_corrupt") }
        if (selected.isNotEmpty() && nodes.none { it.string("id") == selected && it.string("format") == "xrayProfile" }) throw AppFailure("storage_corrupt")
        assignments.keys().forEach { source(it); route(assignments.getString(it)) }
        data.put("settings", Settings.normalize(settings, data.optJSONObject("inboundCredentials")))
    }
    /** Raises the old 256 TCP / 128 UDP defaults once; they refuse new TUN flows under daily load. Later choices are kept. */
    fun migrateSessionLimits(): Boolean {
        if (data.optBoolean("sessionLimitsMigrated")) return false
        val value = settings
        if (value.getInt("tcpMaxConnections") == 256) value.put("tcpMaxConnections", 2048)
        if (value.getInt("udpMaxConnections") == 128) value.put("udpMaxConnections", 1024)
        data.put("settings", value).put("sessionLimitsMigrated", true)
        return true
    }
    /** Allowing other apps makes the key their broadcasts carry, once: turning it off and on keeps the apps working. */
    fun ensureControlKey(): Boolean {
        if (!settings.optBoolean("allowExternalControl") || data.string("externalControlKey").isNotEmpty()) return false
        data.put("externalControlKey", RemoteControl.newKey())
        return true
    }
    fun parseNodes(imported: JSONObject, previous: List<JSONObject>): List<JSONObject> {
        val parsed = imported.objects("profiles").map { it.copy().apply {
            if (string("format") == "telegram" && has("url")) put("config", obj("url" to get("url")))
        } }
        if (parsed.isEmpty() || parsed.size > 4096) throw AppFailure("unsupported_profile")
        fun identity(node: JSONObject) = Native.domain("catalogIdentity", node.getJSONObject("config")).getString("identity")
        val available = previous.sortedBy { if (it.string("id") == selected) 0 else 1 }
        // Index each node's identity once; pairwise matching made O(n*m) native calls
        // and held the repository lock (and Disconnect) for large subscriptions.
        val formats = parsed.map { it.string("format") }.toSet()
        val byIdentity = HashMap<String, ArrayDeque<JSONObject>>()
        available.filter { it.string("format") in formats }.forEach {
            byIdentity.getOrPut(it.string("format") + "\n" + identity(it)) { ArrayDeque() }.add(it)
        }
        val claimed = java.util.Collections.newSetFromMap(java.util.IdentityHashMap<JSONObject, Boolean>())
        val matches = mutableMapOf<Int, JSONObject>()
        parsed.forEachIndexed { i, node ->
            val old = byIdentity[node.string("format") + "\n" + identity(node)]?.removeFirstOrNull()
            if (old != null) { matches[i] = old; claimed.add(old) }
        }
        // A server the user renamed keeps the provider's name for matching.
        fun providerName(node: JSONObject) = node.string("providerName", node.string("name"))
        // Name, protocol, transport and security tell same-named servers apart when a provider rotates their keys.
        fun logicalKey(node: JSONObject): String {
            val outbounds = node.mapObject("config").objects("outbounds")
            val stream = outbounds.firstOrNull()?.mapObject("streamSettings")
            return listOf(node.string("format"), providerName(node), if (outbounds.size > 1) "profile" else outbounds.firstOrNull()?.string("protocol").orEmpty(),
                stream?.string("network").orEmpty(), stream?.string("security").orEmpty()).joinToString("\n")
        }
        val keys = parsed.map(::logicalKey)
        val parsedKeys = keys.groupingBy { it }.eachCount()
        val byKey = available.filter { it !in claimed }.groupBy(::logicalKey)
        val parsedNames = parsed.groupingBy { it.string("name") }.eachCount()
        val previousNames = previous.groupingBy(::providerName).eachCount()
        val byName = available.groupBy(::providerName)
        return parsed.mapIndexed { i, value ->
            if (value.string("format") !in listOf("xrayProfile", "telegram") || value.optJSONObject("config") == null) throw AppFailure("unsupported_profile")
            var old = matches[i]
            if (old == null && parsedKeys[keys[i]] == 1) {
                old = byKey[keys[i]]?.filter { it !in claimed }?.singleOrNull()
                if (old != null) claimed.add(old)
            }
            if (old == null && parsedNames[value.string("name")] == 1 && previousNames[value.string("name")] == 1) {
                old = byName[value.string("name")]?.firstOrNull { it !in claimed && it.string("format") == value.string("format") }
                if (old != null) claimed.add(old)
            }
            var config = value.getJSONObject("config")
            config.objects("elarniGroups").forEach { group ->
                val choice = old?.mapObject("groupOverrides")?.string(group.string("name"))
                if (choice in group.strings("options")) group.put("selected", choice)
            }
            val oldIdentity = old?.let { canonical(it.getJSONObject("config")) }
            var unchanged = oldIdentity == canonical(config)
            // 3x-ui sends one of a server's REALITY shortIds and serverNames at random per fetch; that alone must not restart the tunnel.
            if (old != null && !unchanged && old.has("lastSuccessAt")) {
                config = Native.domain("keepShortIds", obj("previous" to old.getJSONObject("config"), "config" to config, "lastSuccessAt" to old.getDouble("lastSuccessAt"), "now" to now())).getJSONObject("config")
                value.put("config", config)
                unchanged = oldIdentity == canonical(config)
            }
            value.put("id", old?.string("id") ?: newId())
                .put("favorite", old?.optBoolean("favorite") ?: false)
                .put("configurationRevision", if (old != null && unchanged) old.string("configurationRevision", old.string("id")) else newId())
            listOf("lastSuccessAt", "lastSuccessRevision", "groupOverrides", "ipPreference").forEach { key -> if (old?.has(key) == true) value.put(key, old.get(key)) }
            if (old?.has("providerName") == true) value.put("providerName", value.string("name")).put("name", old.string("name"))
            value
        }
    }
    fun importText(text: String): JSONObject? {
        if (text.toByteArray().size !in 1..4*1024*1024) throw AppFailure("input_too_large")
        val input = Native.call("normalizeClientInput", obj("text" to text))
        val content = input.getString("text")
        val decoded = runCatching { Native.domain("decodeRouting", obj("content" to content)) }.getOrNull()
        if (decoded != null) { importRouting(content); return null }
        val url = safeURL(content.trim())
        if (url != null && !(URI(url).host in listOf("t.me", "telegram.me") && URI(url).path == "/proxy")) {
            val id = addSource(url, input)
            return refresh(id)
        }
        val imported = Native.call("importClientProfiles", obj("text" to content))
        // Local imports join one group and skip servers it already has. Hidden
        // imports keep their own group so their sharing limit doesn't spread.
        val hidden = imported.optBoolean("hideURL")
        val group = if (hidden) null else sources.firstOrNull { source -> !source.has("url") && source.objects("nodes").none { it.optBoolean("hideURL") } }
        val id = group?.string("id") ?: newId()
        val kept = group?.objects("nodes").orEmpty()
        fun key(node: JSONObject) = node.string("format") + "\n" + Native.domain("catalogIdentity", node.getJSONObject("config")).getString("identity")
        val known = kept.associateByTo(mutableMapOf(), ::key)
        val nodes = parseNodes(imported, emptyList()).filter { known.putIfAbsent(key(it), it) == null }.onEach { it.put("hideURL", hidden) }
        putSource((group ?: obj("id" to id, "name" to input.string("name", "Local profiles"), "format" to "source", "status" to "ready"))
            .put("nodes", JSONArray(kept + nodes)))
        if (selected.isEmpty()) nodes.firstOrNull { it.string("format") == "xrayProfile" }?.let { data.put("selectedNodeId", it.string("id")) }
        addressedRouting(imported.strings("directives").filter(::isRoutingLink)).forEach { importsRouting(it, id) }
        return null
    }
    /** Imports a provider's routing link. A link the decoder refuses is left out and reported as false:
     *  it must not cost the user the servers it came with. */
    private fun importsRouting(link: String, provider: String): Boolean {
        if (runCatching { Native.domain("decodeRouting", obj("content" to link)) }.isFailure) return false
        importRouting(link, provider = provider)
        return true
    }
    fun addSource(url: String, input: JSONObject = JSONObject()): String {
        if (safeURL(url) == null) throw AppFailure("invalid_target")
        sources.firstOrNull { it.string("url") == url }?.let { return it.string("id") }
        val id = newId()
        putSource(obj("id" to id, "url" to url, "name" to input.string("name", URI(url).host),
            "importedName" to input.opt("name"), "shareLink" to input.opt("shareLink"),
            "format" to "source", "status" to "pending", "nodes" to JSONArray(), "links" to obj("source" to url)))
        return id
    }
    private fun feedURL(source: JSONObject, format: String) = if (format == "source") source.getString("url") else source.mapObject("links").getString(format)
    /** The X-HWID the next refresh of this subscription sends, named by the same Go code. */
    fun deviceID(id: String): String {
        val source = source(id)
        if (!source.has("url")) throw AppFailure("invalid_input")
        return Native.call("subscriptionDeviceID", obj("url" to feedURL(source, source.string("format", "source")), "installationId" to data.getString("installationID"),
            "httpHost" to source.mapObject("fetchOptions").string("httpHost"), "deviceSalt" to source.string("deviceSalt"))).getString("deviceId")
    }
    fun refresh(id: String, approval: JSONArray? = null, format: String? = null): JSONObject? {
        val source = source(id)
        val targetFormat = format ?: source.string("format", "source")
        if (targetFormat !in listOf("source", "raw", "json", "clash")) throw AppFailure("invalid_input")
        val url = feedURL(source, targetFormat)
        val feed = Native.cancellable("fetchSubscription", obj("url" to url, "installationId" to data.getString("installationID"),
            "approvedChain" to (approval ?: if (targetFormat == source.string("format")) source.optJSONArray("approvedChain") ?: JSONArray() else JSONArray()),
            "fallbackHosts" to (source.optJSONArray("fallbackHosts") ?: JSONArray()), "deviceOS" to "Android", "deviceVersion" to Build.VERSION.RELEASE, "deviceModel" to Build.MODEL).merge(source.mapObject("fetchOptions").copy().apply { remove("refreshHours") })
            .put("proxy", Engine.fetchProxy ?: JSONObject.NULL)
            // The provider's backup URL stands in for its main URL, not for other formats.
            .apply { if (targetFormat == "source" && source.has("fallbackURL")) put("fallbackURL", source.getString("fallbackURL")) }
            .apply { if (source.has("deviceSalt")) put("deviceSalt", source.getString("deviceSalt")) })
        feed.optJSONObject("warning")?.let {
            source.put("status", "needsApproval").put("riskCodes", it.optJSONArray("riskCodes"))
            return it.copy().put("subscriptionId", id).put("format", targetFormat)
        }
        val body = feed.getString("body")
        val headers = feed.mapObject("headers")
        val migration = JSONObject().apply { listOf("new-url", "new-domain", "fallback-url").forEach { if (headers.has(it)) put(it, headers.get(it)) } }
        val imported = Native.call("importClientProfiles", obj("text" to body, "sourceURL" to url, "migrationHeaders" to migration))
        // Hidden servers are matched too, so that a refresh keeps them out.
        val hiddenIDs = source.objects("hiddenNodes").map { it.string("id") }.toSet()
        val (hidden, nodes) = parseNodes(imported, source.objects("nodes") + source.objects("hiddenNodes")).partition { it.string("id") in hiddenIDs }
        val metadata = obj("hideURL" to (headers.string("hide-url").lowercase() in listOf("1", "true", "yes") || imported.optBoolean("hideURL")))
        val links = obj("source" to feed.getString("url"))
        readHeaders(headers, metadata, links)
        val info = runCatching { JSONObject(body).mapObject("info") }.getOrDefault(JSONObject())
        mapOf("enabled" to "enabled", "online" to "isOnline").forEach { (key, field) -> if (info.opt(field) is Boolean) metadata.put(key, info.get(field)) }
        if (!metadata.has("announcement")) display(info.string("announce"))?.let { metadata.put("announcement", it) }
        if (info.optBoolean("hide_url")) metadata.put("hideURL", true)
        listOf("upload", "download", "total").forEach { if (!metadata.has(it) && info.opt("${it}Byte") is Number && info.optLong("${it}Byte") >= 0) metadata.put(it, info.get("${it}Byte")) }
        mapOf("raw" to "subUrl", "json" to "subJsonUrl", "clash" to "subClashUrl", "support" to "subSupportUrl").forEach { (key, field) -> safeURL(info.string(field))?.let { links.put(key, it) } }
        // Only the default format's response names the other formats; a refresh in one of them keeps the names it has.
        if (targetFormat != "source") listOf("raw", "json", "clash").forEach { if (!links.has(it) && source.mapObject("links").has(it)) links.put(it, source.mapObject("links").getString(it)) }
        val migrated = imported.string("newSourceURL")
        if (migrated.isNotEmpty()) { source.put("url", migrated).put("shareLink", migrated); listOf("raw", "json", "clash").forEach(links::remove) }
        if (targetFormat == "source" && imported.string("fallbackURL").isNotEmpty()) source.put("fallbackURL", imported.getString("fallbackURL"))
        if (imported.strings("directives").any { !isRoutingLink(it) }) metadata.put("directiveNotice", "Unsupported provider directives")
        // Lines the importer cannot read are left out; the subscription page says how many and of which kind.
        if (imported.optInt("skippedCount") > 0) metadata.put("skippedServers", imported.optInt("skippedCount").toString())
            .put("skippedKinds", imported.objects("skipped").map { it.string("kind") }.filter(String::isNotEmpty).distinct().take(5).joinToString(", "))
        if (imported.optBoolean("systemResolverDNS")) metadata.put("dnsNotice", "The provider's DNS asks this device's resolver, outside the tunnel. Elarni uses its own DNS for these servers.")
        val title = display(headers.string("profile-title")) ?: source.string("importedName", source.string("providerName", URI(url).host))
        val hours = refreshHours(source, metadata)
        source.put("providerName", title).put("name", source.string("manualName", title))
            .put("nodes", JSONArray(nodes)).put("hiddenNodes", JSONArray(hidden)).put("metadata", metadata).put("links", links).put("status", "ready")
            .put("riskCodes", JSONArray()).put("refreshError", JSONObject.NULL).put("failures", 0)
            .put("format", if (migrated.isEmpty()) targetFormat else "source")
            .put("approvedChain", if (migrated.isEmpty()) feed.optJSONArray("approvedChain") ?: JSONArray() else JSONArray())
            .put("lastSuccessfulFetch", now()).put("refreshInterval", hours * 3600)
            .put("nextRefreshAt", now() + hours * 3600 * (0.9 + java.security.SecureRandom().nextDouble() * 0.2))
        if (metadata.opt("routingEnabled") != false) {
            // The header is the provider's routing in any form the decoder reads (a link, bare base64 or JSON, "off").
            addressedRouting(listOf(headers.string("routing")).filter(String::isNotEmpty) + imported.strings("directives").filter(::isRoutingLink))
                .forEach { if (!importsRouting(it, id)) metadata.put("directiveNotice", "Unsupported provider directives") }
        }
        // A server the compiler refuses is left out like a line the importer cannot read; with none left the refresh fails.
        val refused = mutableListOf<JSONObject>()
        try { validateNodes(only = id, refused = refused) } catch (_: OutOfMemoryError) { throw AppFailure("input_too_large") }
        val usable = if (refused.isEmpty()) nodes else {
            val gone = refused.map { it.string("id") }.toSet()
            val kept = nodes.filter { it.string("id") !in gone }
            if (kept.isEmpty()) throw AppFailure("unsupported_profile")
            val kinds = metadata.string("skippedKinds").split(", ") + refused.map { it.mapObject("config").objects("outbounds").firstOrNull()?.string("protocol").orEmpty() }
            metadata.put("skippedServers", ((metadata.string("skippedServers").toIntOrNull() ?: 0) + refused.size).toString())
                .put("skippedKinds", kinds.filter(String::isNotEmpty).distinct().take(5).joinToString(", "))
            source.put("nodes", JSONArray(kept))
            kept
        }
        reconcileSelection()
        if (selected.isEmpty()) usable.firstOrNull { it.string("format") == "xrayProfile" }?.let { data.put("selectedNodeId", it.string("id")) }
        return null
    }
    fun refreshFailed(id: String, code: String) {
        val item = source(id)
        val failures = item.optInt("failures") + 1
        item.put("status", "failed").put("refreshError", code).put("failures", failures)
            .put("nextRefreshAt", if (code in listOf("hwid_required", "hwid_limit")) JSONObject.NULL else now() + retryDelay(failures))
    }
    fun nextRefresh(item: JSONObject): Double? {
        if (!item.has("url") || item.string("status") == "needsApproval") return null
        if (item.optInt("failures") > 0) return if (item.isNull("nextRefreshAt")) null else item.optDouble("nextRefreshAt")
        val hours = refreshHours(item)
        if (item.has("lastSuccessfulFetch") && item.optInt("refreshInterval") != hours * 3600) return item.getDouble("lastSuccessfulFetch") + hours * 3600
        return if (item.isNull("nextRefreshAt")) null else item.optDouble("nextRefreshAt")
    }
    // The user's override, else the provider's Profile-Update-Interval, else the app setting.
    fun refreshHours(item: JSONObject, metadata: JSONObject = item.mapObject("metadata")) =
        item.mapObject("fetchOptions").string("refreshHours").toIntOrNull()
            ?: metadata.optInt("updateIntervalHours").takeIf { it > 0 } ?: settings.getInt("subscriptionAutoUpdateHours")
    fun reconcileSelection() {
        if (selected.isNotEmpty() && nodes.none { it.string("id") == selected }) data.put("selectedNodeId", JSONObject.NULL)
    }
    fun selectGroup(nodeId: String, groupName: String, choice: String) {
        val node = node(nodeId)
        val group = node.mapObject("config").objects("elarniGroups").firstOrNull { it.string("name") == groupName } ?: throw AppFailure("invalid_input")
        if (choice !in group.strings("options")) throw AppFailure("invalid_input")
        group.put("selected", choice)
        node.put("groupOverrides", node.mapObject("groupOverrides").put(groupName, choice)).put("configurationRevision", newId())
    }
    /** Once the user assigns a subscription's routing, the provider's directives no longer change it; refreshes still update the provider's own profile. */
    fun assignRouting(sourceId: String, routeId: String?, byUser: Boolean = true) {
        val source = source(sourceId)
        if (!byUser && source.optBoolean("manualRouting")) return
        if (routeId == null) assignments.remove(sourceId) else assignments.put(sourceId, routeId)
        if (byUser) source.put("manualRouting", true)
    }
    fun importRouting(content: String, provider: String? = null, update: String? = null, forceNew: Boolean = false): String? {
        val parsed = Native.domain("decodeRouting", obj("content" to content)).getJSONObject("import")
        val target = provider ?: nodes.firstOrNull { it.string("id") == selected }?.let { sourceFor(selected).string("id") }
        if (parsed.string("action") == "off") {
            if (target == null) throw AppFailure("no_selection")
            assignRouting(target, null, byUser = provider == null); return null
        }
        val profile = parsed.getJSONObject("profile")
        var title = display(profile.string("Name")) ?: "Routing profile"
        if (forceNew) {
            // A new profile takes a name of its own; the same name is how a repeated import finds the profile to replace.
            val base = title; var suffix = 2
            while (routes.any { it.string("name") == title }) title = "$base ${suffix++}"
            profile.put("Name", title)
        }
        val previous = if (forceNew) null else if (update != null) route(update) else routes.firstOrNull {
            if (provider == null) it.string("providerSubscriptionId").isEmpty() && it.string("name") == title else it.string("providerSubscriptionId") == provider
        }
        val id = previous?.string("id") ?: newId()
        if (parsed.optBoolean("activate")) {
            if (target == null) throw AppFailure("no_selection")
            assignRouting(target, id, byUser = provider == null)
        }
        if (provider != null && previous?.optBoolean("edited") == true) { previous.put("original", profile); return id }
        val retained = JSONObject()
        profile.objects("ManagedSources").forEach { source ->
            val old = previous?.mapObject("profile")?.objects("ManagedSources")?.firstOrNull { old -> listOf("id", "url", "destination", "matchMode").all { old.opt(it) == source.opt(it) } }
            val values = previous?.mapObject("lists")?.opt(source.string("id"))
            if (old != null && values != null) retained.put(source.string("id"), values)
        }
        val value = previous?.copy() ?: JSONObject()
        value.put("id", id).put("name", title).put("source", if (provider != null) "provider" else previous?.string("source", "local") ?: "local")
            .put("providerSubscriptionId", provider ?: previous?.opt("providerSubscriptionId") ?: JSONObject.NULL)
            .put("edited", update != null).put("enabled", previous?.optBoolean("enabled", true) ?: true)
            .put("profile", profile).put("original", if (provider != null) profile else previous?.optJSONObject("original") ?: profile)
            .put("lists", retained).put("routeModel", Native.domain("mergeManagedRouting", obj("profile" to profile, "lists" to retained)).getJSONObject("routeModel"))
        if (previous == null || canonical(previous.mapObject("profile")) != canonical(profile)) {
            // A rule edit reduces the downloaded geofiles again; only new geofile links download them again.
            val kept = previous?.string("assetRevision").orEmpty().ifEmpty { previous?.string("originalAssetRevision").orEmpty() }
            if (kept.isNotEmpty() && listOf("Geoipurl", "Geositeurl").all { previous!!.mapObject("profile").string(it) == profile.string(it) }) value.put("originalAssetRevision", kept)
            else value.remove("originalAssetRevision")
            value.remove("assetRevision")
        }
        value.put("geofileStatus", if (listOf("Geoipurl", "Geositeurl").any { profile.string(it).isNotEmpty() }) "pending" else "ready")
        value.put("nextManagedRefreshAt", if (profile.objects("ManagedSources").isEmpty()) JSONObject.NULL else now())
        putRoute(value)
        return id
    }
    // A full refresh updates each list on its own: a failed one keeps its last download,
    // and the route records the first error and retries on the subscription schedule.
    fun refreshManaged(id: String, sourceId: String = "") {
        val route = route(id); val profile = route.getJSONObject("profile")
        val sources = profile.objects("ManagedSources").filter { sourceId.isEmpty() || it.string("id") == sourceId }
        if (sourceId.isNotEmpty() && sources.isEmpty()) throw AppFailure("not_found")
        val previous = route.mapObject("lists")
        val lists = if (sourceId.isEmpty()) JSONObject() else previous.copy()
        var error: String? = null
        sources.forEach { source ->
            try {
                val feed = resource(id, source.getString("url"), "domains")
                val text = String(Base64.decode(feed.getString("body"), Base64.DEFAULT), Charsets.UTF_8)
                lists.put(source.getString("id"), Native.domain("parseManagedDomains", obj("text" to text, "matchMode" to source.getString("matchMode"))).getJSONArray("domains"))
            } catch (failure: AppFailure) {
                if (sourceId.isNotEmpty() || failure.code in listOf("cancelled", "fetch_cancelled")) throw failure
                error = error ?: failure.code
                previous.optJSONArray(source.getString("id"))?.let { lists.put(source.getString("id"), it) }
            }
        }
        // Merged lists over the routing limits are unusable, so the route keeps its previous ones.
        val model = try { Native.domain("mergeManagedRouting", obj("profile" to profile, "lists" to lists)).getJSONObject("routeModel") }
            catch (failure: AppFailure) { if (sourceId.isNotEmpty()) throw failure; error = failure.code; null }
        if (model != null) route.put("lists", lists).put("routeModel", model)
        if (sourceId.isNotEmpty()) { route.put("managedError", JSONObject.NULL); return }
        val failures = if (error == null) 0 else route.optInt("managedFailures") + 1
        route.put("managedError", error ?: JSONObject.NULL).put("managedFailures", failures)
            .put("nextManagedRefreshAt", now() + if (error == null) 86400 else retryDelay(failures))
    }
    /** With a stored copy's [validators] (etag, lastModified) the reply may be notModified, with no body.
     *  A geofile goes to [destination] as it arrives, and the reply has its size instead of a body. */
    fun resource(routeID: String, url: String, kind: String, validators: JSONObject = JSONObject(), destination: java.io.File? = null): JSONObject {
        val feed = Native.cancellable("fetchResource", obj("url" to url, "resourceKind" to kind,
            "approvedChain" to (route(routeID).mapObject("approvedResources").optJSONArray(url) ?: JSONArray()),
            "etag" to validators.string("etag"), "lastModified" to validators.string("lastModified"))
            .put("proxy", Engine.fetchProxy ?: JSONObject.NULL).put("destination", destination?.absolutePath))
        feed.optJSONObject("warning")?.let { throw ResourceReview(this, routeID, url, it) }
        return feed
    }
    fun compile(id: String, context: Context? = null, vpn: Boolean = settings.getBoolean("xrayTunEnabled"), inboundAuth: JSONObject? = null): JSONObject =
        compileNode(node(id), routeFor(id), settings, context, vpn, inboundAuth)
    private fun compileNode(node: JSONObject, route: JSONObject?, setting: JSONObject, context: Context?, vpn: Boolean, inboundAuth: JSONObject? = null): JSONObject {
        if (node.string("format") != "xrayProfile") throw AppFailure("unsupported_profile")
        return compiled(compileRequest(node, route, setting, context, vpn, inboundAuth).put("profile", node.getJSONObject("config")))
    }
    /** The compile request of [node] without its profile: of the server it holds only the IP preference. */
    private fun compileRequest(node: JSONObject, route: JSONObject?, setting: JSONObject, context: Context?, vpn: Boolean, inboundAuth: JSONObject?): JSONObject {
        val preference = node.string("ipPreference", setting.string("profilePreferredIP", "inherit"))
        val perApp = context != null && setting.getString("perAppMode") != "off"
        // An uninstalled app has no UID. Its package name never matches one, so the rest of the list still applies.
        fun process(name: String) = context?.takeIf { perApp }?.let { runCatching { it.packageManager.getApplicationInfo(name, 0).uid.toString() }.getOrNull() } ?: name
        val runtime = obj("httpInboundEnabled" to setting.getBoolean("httpInboundEnabled"), "httpPort" to setting.getInt("httpPort"),
            "allowLan" to setting.getBoolean("allowLAN"), "fragmentationEnabled" to setting.getBoolean("fragmentationEnabled"),
            "fragmentPackets" to setting.getString("fragmentPackets"), "fragmentLength" to setting.getString("fragmentLength"), "fragmentInterval" to setting.getString("fragmentInterval"),
            "muxEnabled" to setting.getBoolean("muxEnabled"), "preferredIp" to node.string("ipPreference", setting.getString("preferredIP")),
            "connectionIdleSeconds" to setting.getInt("idleTimeoutSeconds"), "sniffingEnabled" to setting.getBoolean("sniffingEnabled"),
            "useDnsFromJson" to setting.getBoolean("useDNSFromJSON"), "profileDnsMode" to setting.getString("profileDNSMode"),
            "perAppMode" to setting.getString("perAppMode"), "perAppProcesses" to JSONArray(setting.strings("perAppProcesses").map(::process)))
        // Validating every server leaves targets out: one deleted server must fail its app's connect, not every catalog change.
        if (perApp) runtime.put("perAppTargets", perAppTargets(setting, ::process))
        (if (setting.getBoolean("inboundAuthEnabled")) data.getJSONObject("inboundCredentials") else inboundAuth)?.let { runtime.put("inboundAuth", it) }
        val request = obj("socksPort" to setting.getInt("socksPort"), "packetBackend" to if (vpn) "xrayTun" else "nativeTun2Proxy", "tunMtu" to ElarniVpnService.MTU, "runtime" to runtime)
        route?.let { request.put("routes", it.getJSONObject("routeModel")) }
        if (preference != "inherit") request.put("preferredIp", preference)
        return request
    }
    private fun compiled(request: JSONObject): JSONObject {
        val config = JSONObject(Native.domain("compileProfile", request).getString("configUtf8"))
        config.put("log", obj("loglevel" to "none"))
        config.put("stats", JSONObject())
        config.put("policy", config.mapObject("policy").put("system", obj("statsInboundUplink" to true, "statsInboundDownlink" to true)))
        // Android owns routes and upstream selection; core owns the userspace stack.
        config.objects("inbounds").filter { it.string("protocol") == "tun" }.forEach { inbound ->
            val options = inbound.mapObject("settings")
            options.remove("autoSystemRoutingTable"); options.remove("autoOutboundsInterface")
            options.put("name", "elarni").put("mtu", ElarniVpnService.MTU)
            inbound.put("settings", options)
        }
        return config
    }
    // Apps sharing a UID share one rule, so the first listed app's target wins.
    private fun perAppTargets(setting: JSONObject, process: (String) -> String): JSONArray {
        val targets = setting.mapObject("perAppTargets"); val seen = mutableSetOf<String>()
        return JSONArray(setting.strings("perAppProcesses").filter(targets::has).mapNotNull { name ->
            val id = process(name).takeIf(seen::add) ?: return@mapNotNull null
            val target = targets.getString(name)
            when {
                target.startsWith("node:") -> obj("process" to id, "target" to "server", "server" to (nodes.firstOrNull { it.string("id") == target.substring(5) && it.string("format") == "xrayProfile" }
                    ?: throw AppFailure("per_app_target_missing")).getJSONObject("config"))
                target.startsWith("proxy:") -> obj("process" to id, "target" to "proxy", "proxy" to target.substring(6))
                else -> obj("process" to id, "target" to target)
            }
        })
    }
    /** Compiles each server in turn, which validates it: 4,096 compiled trees at once outgrew the API 30 heap.
     *  A request that compiled before is not compiled again, so an edit costs the servers it changes.
     *  With [refused], only the subscription [only] is compiled and a server the compiler refuses is collected, not thrown. */
    fun validateNodes(only: String? = null, refused: MutableList<JSONObject>? = null, valid: () -> Unit = {}) {
        // Resolve settings and each source's route once; per-node lookups were quadratic.
        val setting = settings
        val vpn = setting.getBoolean("xrayTunEnabled")
        val assigned = assignments
        val allRoutes = routes
        // Servers with one route and one IP preference differ only in their profile.
        val shared = HashMap<String, Pair<JSONObject, String>>()
        sources.forEach { source ->
            if (only != null && source.string("id") != only) return@forEach
            valid()
            val routeId = assigned.string(source.string("id"))
            val route = allRoutes.firstOrNull { it.string("id") == routeId && it.optBoolean("enabled", true) }
            source.objects("nodes").forEach { node ->
                if (node.getString("format") != "xrayProfile") return@forEach
                val (request, context) = shared.getOrPut(route?.string("id").orEmpty() + "\n" + node.string("ipPreference")) {
                    compileRequest(node, route, setting, null, vpn, null).let { it to sha256(it.toString()) }
                }
                val profile = node.getJSONObject("config")
                val key = sha256(context + profile.toString())
                if (synchronized(validated) { validated[key] } != null) return@forEach
                try { compiled(request.put("profile", profile)) }
                catch (error: AppFailure) { if (refused == null || error.code != "unsupported_profile") throw error; refused.add(node); return@forEach }
                synchronized(validated) { validated[key] = true }
            }
        }
    }
    fun share(id: String, subscription: Boolean): JSONObject {
        val source = if (subscription) source(id) else sourceFor(id)
        if (source.mapObject("metadata").optBoolean("hideURL")) throw AppFailure("sharing_disabled")
        if (source.has("url") && !source.mapObject("metadata").has("hideURL")) throw AppFailure("sharing_refresh_required")
        val text = if (subscription) source.string("shareLink", source.string("url")) else {
            val node = node(id)
            if (node.optBoolean("hideURL")) throw AppFailure("sharing_disabled")
            if (node.string("format") == "telegram") node.mapObject("config").getString("url") else node.getJSONObject("config").copy().put("remarks", node.getString("name")).toString(2)
        }
        if (text.isEmpty()) throw AppFailure("unsupported_profile")
        return Native.call("clientQR", obj("text" to text)).put("text", text)
    }
    /** A profile with several outbounds has no share link; it is shared from its own page. */
    // Nor do the protocols libXray share/generate_share.go writes no link for, such as WireGuard and HTTP.
    fun linkable(node: JSONObject) = node.string("format") == "telegram" || node.mapObject("config").objects("outbounds").singleOrNull()
        ?.string("protocol") in setOf("vless", "vmess", "trojan", "shadowsocks", "socks", "hysteria", "tuic")
    /** Servers of a local group, which has no subscription link, as share links in group order. */
    fun shareLinks(ids: List<String>): JSONObject {
        if (ids.isEmpty()) throw AppFailure("invalid_input")
        val text = ids.joinToString("\n") { id ->
            val node = node(id)
            if (node.optBoolean("hideURL") || sourceFor(id).mapObject("metadata").optBoolean("hideURL")) throw AppFailure("sharing_disabled")
            if (!linkable(node)) throw AppFailure("unsupported_profile")
            if (node.string("format") == "telegram") node.mapObject("config").getString("url")
            else {
                // The link takes its name from the outbound tag.
                val outbound = node.mapObject("config").objects("outbounds").single().copy().put("tag", node.getString("name"))
                Native.call("convertXrayJsonToShareLinks", obj("xrayJson" to obj("outbounds" to JSONArray(listOf(outbound))).toString())).getString("links")
                    .also { if (it.startsWith("{")) throw AppFailure("unsupported_profile") }
            }
        }
        return Native.call("clientQR", obj("text" to text)).put("text", text)
    }
    fun backup(): JSONObject {
        sources.forEach { if (it.mapObject("metadata").optBoolean("hideURL") || it.objects("nodes").any { node -> node.optBoolean("hideURL") }) throw AppFailure("sharing_disabled")
            if (it.has("url") && !it.mapObject("metadata").has("hideURL")) throw AppFailure("sharing_refresh_required") }
        fun pick(source: JSONObject, keys: List<String>) = JSONObject().apply { keys.forEach { if (source.has(it) && !source.isNull(it)) put(it, source.get(it)) } }
        val nodeKeys = listOf("id", "name", "providerName", "format", "config", "groupOverrides", "ipPreference", "favorite")
        return obj("version" to 1, "selectedNodeId" to data.opt("selectedNodeId"), "assignments" to assignments,
            "subscriptions" to JSONArray(sources.map { source -> pick(source, listOf("id", "name", "url", "shareLink", "fallbackHosts", "fetchOptions", "manualRouting"))
                .put("nodes", JSONArray(source.objects("nodes").map { pick(it, nodeKeys) }))
                .apply { if (source.objects("hiddenNodes").isNotEmpty()) put("hiddenNodes", JSONArray(source.objects("hiddenNodes").map { pick(it, nodeKeys) })) } }),
            "routes" to JSONArray(routes.map { route -> pick(route, listOf("id", "profile", "providerSubscriptionId", "enabled", "edited")).apply {
                if (route.string("providerSubscriptionId").isNotEmpty()) put("providerProfile", route.getJSONObject("original"))
            } }))
    }
    fun restoreBackup(backup: JSONObject) {
        val sourceIDs = mutableMapOf<String, String>(); val nodeIDs = mutableMapOf<String, String>(); val routeIDs = mutableMapOf<String, String>()
        data.put("subscriptions", JSONArray()).put("profiles", JSONArray()).put("assignments", JSONObject()).put("selectedNodeId", JSONObject.NULL)
        backup.objects("subscriptions").forEach { raw ->
            val id = newId(); sourceIDs[raw.getString("id")] = id
            // Hidden servers are restored with the others, so that their overrides apply, and set aside after.
            val rawNodes = raw.objects("nodes") + raw.objects("hiddenNodes")
            val values = if (rawNodes.isEmpty()) emptyList() else parseNodes(obj("profiles" to JSONArray(rawNodes)), emptyList())
            values.forEachIndexed { index, node -> nodeIDs[rawNodes[index].getString("id")] = node.getString("id"); node.put("favorite", rawNodes[index].optBoolean("favorite")) }
            val value = raw.copy().put("id", id).put("nodes", JSONArray(values)).put("hiddenNodes", JSONArray()).put("manualName", raw.getString("name"))
                .put("format", "source").put("status", if (raw.string("url").isEmpty()) "ready" else "needsApproval")
                .put("metadata", if (raw.string("url").isEmpty()) obj("hideURL" to false) else JSONObject()).put("approvedChain", JSONArray())
                .put("links", obj("source" to raw.opt("url")))
            if (raw.string("url").isEmpty()) value.remove("url")
            putSource(value)
            // Overrides outlive provider group edits; as on desktop, a stale one must not make the whole backup unrestorable.
            values.forEachIndexed { index, node -> rawNodes[index].mapObject("groupOverrides").let { overrides -> overrides.keys().forEach {
                try { selectGroup(node.getString("id"), it, overrides.getString(it)) } catch (error: AppFailure) { if (error.code != "invalid_input") throw error }
            } } }
            val shown = values.size - raw.objects("hiddenNodes").size
            value.put("nodes", JSONArray(values.take(shown))).put("hiddenNodes", JSONArray(values.drop(shown)))
        }
        backup.objects("routes").forEach { raw ->
            val id = importRouting(raw.getJSONObject("profile").toString(), forceNew = true) ?: throw AppFailure("invalid_backup")
            routeIDs[raw.getString("id")] = id
            route(id).put("enabled", raw.optBoolean("enabled")).put("edited", raw.optBoolean("edited"))
            if (raw.has("providerProfile")) route(id).put("original", Native.domain("decodeRouting", obj("content" to raw.getJSONObject("providerProfile").toString())).getJSONObject("import").getJSONObject("profile"))
                .put("providerSubscriptionId", sourceIDs[raw.string("providerSubscriptionId")]).put("source", "provider")
        }
        backup.mapObject("assignments").let { it.keys().forEach { key -> assignments.put(sourceIDs[key] ?: throw AppFailure("invalid_backup"), routeIDs[it.getString(key)] ?: throw AppFailure("invalid_backup")) } }
        data.put("selectedNodeId", nodeIDs[backup.string("selectedNodeId")] ?: JSONObject.NULL)
            .put("connectionIntent", false).remove("automation")
        // Settings outlive a restore, but its servers have new IDs. A target the backup lacks fails its app's connect until another is chosen.
        data.mapObject("settings").optJSONObject("perAppTargets")?.let { targets ->
            targets.keys().asSequence().toList().forEach { app ->
                val target = targets.getString(app)
                if (target.startsWith("node:")) nodeIDs[target.substring(5)]?.let { targets.put(app, "node:$it") }
            }
        }
    }
    companion object {
        private val installationPattern = Regex("^[a-f0-9]{64}$")
        private val idPattern = Regex("^[A-Za-z0-9-]{1,128}$")
        // Compile requests that passed validateNodes, by digest; twice the server limit, least recently used first out.
        private val validated = object : LinkedHashMap<String, Boolean>(256, 0.75f, true) {
            override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, Boolean>) = size > 8192
        }
        private fun sha256(text: String) = java.security.MessageDigest.getInstance("SHA-256").digest(text.toByteArray())
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        // The SNI a probe's handshake sends: bulk tests run at most two probes per SNI,
        // as TSPU counts handshakes per SNI. TLS without a name sends the address.
        fun probeKey(node: JSONObject): String? {
            for (outbound in node.mapObject("config").objects("outbounds")) {
                val stream = outbound.optJSONObject("streamSettings"); val settings = outbound.optJSONObject("settings")
                val server = (settings?.optJSONArray("vnext") ?: settings?.optJSONArray("servers"))?.optJSONObject(0)
                val key = listOf("realitySettings", "tlsSettings").firstNotNullOfOrNull { stream?.optJSONObject(it)?.optString("serverName")?.ifEmpty { null } }
                    ?: (settings?.optString("address")?.ifEmpty { null } ?: server?.optString("address")?.ifEmpty { null })
                        ?.takeIf { stream?.optString("security") in listOf("tls", "reality") }
                if (key != null) return key.lowercase()
            }
            return null
        }
        /** A subscription response's provider headers, added to [metadata] and [links]. */
        fun readHeaders(headers: JSONObject, metadata: JSONObject, links: JSONObject) {
            val seen = mutableSetOf<String>()
            headers.string("subscription-userinfo").split(';').forEach {
                val parts = it.split('=').map(String::trim)
                if (parts.size == 2 && parts[0] in listOf("upload", "download", "total", "expire")) {
                    if (!seen.add(parts[0])) metadata.remove(parts[0])
                    else parts[1].toLongOrNull()?.takeIf { it >= 0 }?.let { number -> metadata.put(parts[0], number) }
                }
            }
            mapOf("announcement" to "announce", "bannerText" to "banner-text", "bannerButtonText" to "banner-button-text").forEach { (key, header) -> display(headers.string(header))?.let { metadata.put(key, it) } }
            mapOf("routingEnabled" to "routing-enable", "hideSettings" to "hide-settings", "deviceRegistered" to "x-hwid-active").forEach { (key, header) ->
                when (headers.string(header).lowercase()) { "1", "true" -> metadata.put(key, true); "0", "false" -> metadata.put(key, false) }
            }
            mapOf("support" to "support-url", "account" to "profile-web-page-url", "banner" to "banner-button-url").forEach { (key, header) -> safeURL(headers.string(header))?.let { links.put(key, it) } }
            safeURL(headers.string("premium-url"))?.let { links.put("banner", it) }
            Regex("\\d{1,6}").matchEntire(headers.string("profile-update-interval").trim())?.value?.toInt()?.takeIf { it > 0 }
                ?.let { metadata.put("updateIntervalHours", it.coerceAtMost(168)) }
        }
        /** Without lockdown, which blocks the apps a VPN leaves out, apps that need no tunnel stay out of the userspace stack:
         *  the VPN Builder's allowed (true) or disallowed (false) apps besides [self], or null when every app enters. */
        fun tunnelApps(settings: JSONObject, self: String, uid: (String) -> Int?): Pair<Boolean, List<String>>? {
            // An uninstalled app has no UID; Android would keep its name in a list and match no app.
            val installed = settings.strings("perAppProcesses").filter { it != self }.mapNotNull { name -> uid(name)?.let { name to it } }
            val targets = settings.mapObject("perAppTargets")
            return when (settings.string("perAppMode")) {
                // The core still routes each listed app, whatever its target.
                "proxyOnly" -> if (installed.isEmpty()) null else true to installed.map { it.first }
                "bypass" -> {
                    // Apps sharing a UID share one rule, set by the first listed app with a target, as in perAppTargets.
                    val shared = mutableMapOf<Int, String>()
                    installed.forEach { (name, id) -> if (targets.has(name)) shared.putIfAbsent(id, targets.getString(name)) }
                    false to installed.filter { (_, id) -> (shared[id] ?: "direct") == "direct" }.map { it.first }
                }
                else -> null
            }
        }
        /**
         * Each listed app's UID, or null for one not installed. Android works out the tunnel's apps by UID when the VPN
         * starts, and so do the per-app rules, so an app installed, removed or reinstalled later needs a new start.
         */
        fun listedUids(settings: JSONObject, uid: (String) -> Int?): Map<String, Int?>? =
            if (settings.string("perAppMode") == "off") null else settings.strings("perAppProcesses").associateWith(uid)
        // Subscriptions, managed lists and geodata retry a failed refresh after 60, 300, then 1800 s.
        fun retryDelay(failures: Int) = listOf(60, 300, 1800)[(failures - 1).coerceIn(0, 2)]
        // Whole hours from 1 to 168, without a leading zero.
        val validRefreshHours = Regex("[1-9]|[1-9][0-9]|1[0-5][0-9]|16[0-8]")
        // Other local apps must not reach a fresh install's listeners without a login (v2rayNG #5457).
        fun generatedLogin() = obj("username" to newId().take(32), "password" to newId().take(32))
        fun empty() = Catalog(obj("version" to 1, "installationID" to newId(), "settings" to Settings.defaults().put("inboundAuthEnabled", true),
            "inboundCredentials" to generatedLogin(),
            "sessionLimitsMigrated" to true, "subscriptions" to JSONArray(), "profiles" to JSONArray(), "assignments" to JSONObject()))
        fun safeURL(text: String): String? = try {
            val value = URI(text)
            if (text.isEmpty() || text.length > 16384 || text.any { it.code < 32 } || value.scheme?.lowercase() !in listOf("http", "https") || value.host.isNullOrEmpty() || value.userInfo != null || value.fragment != null) null else text
        } catch (_: Exception) { null }
        fun isRoutingLink(text: String) = listOf("happ://routing/", "elarni://routing/", "incy://routing/").any { text.startsWith(it) }
        // Panels such as 3x-ui send their Happ routing to every client (3x-ui #5999), so links addressed to Elarni win when a feed has any.
        fun addressedRouting(links: List<String>) = links.filter { it.startsWith("elarni://routing/") }.ifEmpty { links }
        fun display(text: String): String? {
            if (text.isBlank() || text.toByteArray().size > 16384) return null
            val decoded = if (text.startsWith("base64:", ignoreCase = true)) runCatching { Native.domain("decodeBase64Text", obj("text" to text.substring(7))).getString("text") }.getOrNull() ?: return null else text
            return decoded.filter { !it.isISOControl() }.trim().takeIf { it.isNotEmpty() }
        }
        fun canonical(value: Any?): String = when(value) {
            is JSONObject -> value.keys().asSequence().toList().sorted().joinToString(",", "{", "}") { JSONObject.quote(it) + ":" + canonical(value.get(it)) }
            is JSONArray -> (0 until value.length()).joinToString(",", "[", "]") { canonical(value.get(it)) }
            is String -> JSONObject.quote(value)
            else -> value.toString()
        }
    }
}
