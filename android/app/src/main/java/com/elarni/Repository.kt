package com.elarni

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Intent
import android.content.pm.PackageManager
import android.net.VpnService
import android.os.Build
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.Executors
import java.util.concurrent.ExecutorCompletionService
import java.util.concurrent.TimeUnit

data class AppState(
    val catalog: JSONObject = Catalog.empty().data,
    val loading: Boolean = true,
    val busy: Boolean = false,
    val connection: String = "disconnected",
    val error: String? = null,
    /** The subscription whose refresh failed with this error, if one did. */
    val errorSource: String? = null,
    val event: Long = 0,
    val issues: List<JSONObject> = emptyList(),
    val approval: JSONObject? = null,
    val metrics: JSONObject = JSONObject(),
    val pings: Map<String, JSONObject> = emptyMap(),
    /** Check exit results, kept apart from latency: they follow Cloudflare's trace, not the configured test. */
    val exits: Map<String, JSONObject> = emptyMap(),
    val automationStatus: String = "disabled",
    /** Recovery saw only Russian-entry servers get through and tries them first. */
    val whitelistMode: Boolean = false,
    /** Whether the connected server passes traffic: "ok", "noTraffic", or null before the first check. */
    val liveness: String? = null,
    /** Wall-clock milliseconds when the server started failing that check. */
    val noTrafficSince: Long? = null,
)

// Up to two probes share an SNI, so a part takes at most four probe timeouts.
private const val CONNECTED_TEST_BATCH = 8
private const val CRASH_RESTORE_MS = 10 * 60_000L

class Repository(private val app: ElarniApplication) {
    // An error a task leaves uncaught must not end the process and its VPN; an Error still does, and a crash is restored.
    val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO + CoroutineExceptionHandler { _, error ->
        if (error !is Exception) throw error
        if (code(error) != "cancelled") report(error)
    })
    private val mutex = Mutex()
    private val epoch = AtomicLong()
    private val stopRequested = AtomicBoolean(false)
    private val store = EncryptedStore(app)
    private val assets = RoutingAssets(app)
    val engine = Engine(app, assets)
    private var catalog = Catalog.empty()
    private var revision = 0L
    private var storageFailure: String? = null
    /** The stored data failed to load, so the catalog in memory is a placeholder that must never replace it. */
    private var loadFailed = false
    private var automation = Automation(JSONObject())
    private var approval: Approval? = null
    /** Routes whose background refresh raised an approval, until when the other routes go first. */
    private val approvalBackoff = mutableMapOf<String, Double>()
    /** Counts changes to [catalog], so that publishing copies it only when it changed. */
    private var edits = 0L
    private var copied = -1L
    private data class Approval(val token: String, val base: Long, val expires: Double, val candidate: Catalog, val warning: JSONObject,
        val command: String = "", val args: JSONObject = JSONObject())
    private val mutable = MutableStateFlow(AppState())
    val state = mutable.asStateFlow()
    private val ready = CompletableDeferred<Unit>()
    init {
        scope.launch {
            var refresh = false
            mutex.withLock {
                try {
                    store.load()?.let { saved ->
                        if (saved.optInt("journalVersion") != 1) throw AppFailure("storage_corrupt")
                        // Recovery publishes only the last committed configuration, never an interrupted candidate.
                        catalog = Catalog(saved.getJSONObject("committed"))
                        catalog.validate()
                        // A catalog that allowed external control before keys existed gets one, which Settings shows.
                        if (catalog.migrateSessionLimits() or catalog.ensureControlKey() or saved.has("pending")) persist(catalog)
                    }
                    automation = Automation(catalog.data.mapObject("automationEpisode"))
                    automation.intent = catalog.data.optBoolean("connectionIntent")
                    retireAssets()
                } catch (error: Exception) { loadFailed = true; storageFailure = code(error); mutable.update { it.copy(error = storageFailure, event = it.event + 1) } }
                try {
                    publish(loading = false)
                    // Android restarts a killed sticky service as a background start and stops it again, so the
                    // next process start brings back a VPN the system ended along with its process, before anyone awaits it.
                    runCatching { if (endedWhileConnected()) app.startForegroundService(Intent(app, ElarniVpnService::class.java)) }
                        .onFailure { report(AppFailure("foreground_start_denied")) }
                    refresh = backgroundWork()
                } finally { ready.complete(Unit) }
            }
            // Outside the lock: a refresh job this start serves is waiting for it.
            app.scheduleRefresh(refresh)
        }
    }
    private fun endedWhileConnected(): Boolean {
        // Without its service the VPN was already down: a failed Connect, a reboot or an earlier start that stayed down.
        if (!automation.intent || storageFailure != null || !app.serviceHeld) return false
        val exit = app.getSystemService(ActivityManager::class.java).getHistoricalProcessExitReasons(app.packageName, 0, 1).firstOrNull() ?: return false
        // Only an exit in this boot: a reboot follows launchAtBoot, and a force stop or an update stays down.
        val booted = System.currentTimeMillis() - android.os.SystemClock.elapsedRealtime()
        if (exit.timestamp <= booted) return false
        if (exit.reason in listOf(ApplicationExitInfo.REASON_SIGNALED, ApplicationExitInfo.REASON_LOW_MEMORY,
            ApplicationExitInfo.REASON_EXCESSIVE_RESOURCE_USAGE, ApplicationExitInfo.REASON_DEPENDENCY_DIED, ApplicationExitInfo.REASON_OTHER)) return true
        if (exit.reason !in listOf(ApplicationExitInfo.REASON_CRASH, ApplicationExitInfo.REASON_CRASH_NATIVE, ApplicationExitInfo.REASON_EXIT_SELF, ApplicationExitInfo.REASON_ANR)) return false
        // A crash (a Go panic exits the process itself) comes back at most once in 10 minutes, so one that recurs cannot loop.
        val restores = app.getSharedPreferences("watch", android.content.Context.MODE_PRIVATE)
        val time = System.currentTimeMillis()
        if (time - restores.getLong("crashRestoredAt", 0) in 0 until CRASH_RESTORE_MS) return false
        return restores.edit().putLong("crashRestoredAt", time).commit()
    }
    /** Whether the background job has anything to do: a subscription or route list to refresh, or an expiry to remind of. */
    private fun backgroundWork() = catalog.sources.any { catalog.nextRefresh(it) != null || catalog.settings.optBoolean("expiryReminders") && it.mapObject("metadata").has("expire") } ||
        catalog.routes.any { !it.isNull("nextManagedRefreshAt") || !it.isNull("nextGeoRefreshAt") }
    private fun retireAssets() = assets.retire(catalog.routes.flatMap { listOf(it.string("assetRevision"), it.string("originalAssetRevision")) }.toSet())
    suspend fun awaitReady() = ready.await()
    private fun check(generation: Long) { if (generation != epoch.get()) throw AppFailure("cancelled") }
    private fun code(error: Exception) = (error as? AppFailure)?.code ?: "operation_failed"
    fun report(error: Exception, source: String? = null) {
        val code = code(error)
        val issue = obj("code" to code, "timestamp" to now())
        mutable.update { it.copy(error = code, errorSource = source, event = it.event + 1, issues = (listOf(issue) + it.issues).take(40)) }
    }
    private var published: String? = null
    private fun publish(loading: Boolean = mutable.value.loading) {
        // The 2 s tick publishes too; an unchanged state must not re-parse the
        // catalog, recompose the UI or repost the tile and notification.
        val signature = listOf(loading, edits, approval?.warning, automation.status, automation.whitelist, mutable.value.connection, mutable.value.liveness).joinToString("\u0000")
        if (signature == published) return
        published = signature
        // The core reads its log level as it records, so the saved one applies without a reconnect.
        runCatching { Native.call("setLogLevel", obj("level" to catalog.settings.string("logLevel", "warning"))) }
        val copy = if (copied == edits) mutable.value.catalog else catalog.data.copy().also { copied = edits }
        mutable.update { it.copy(catalog = copy, loading = loading,
            approval = approval?.warning?.copy(), automationStatus = automation.status, whitelistMode = automation.whitelist) }
        app.refreshTile()
        Widgets.refresh(app, mutable.value)
        WiFiRule.sync(app, catalog)
        engine.service?.updateNotification(mutable.value.connection)
    }
    private fun persist(value: Catalog, candidate: Catalog? = null) {
        // Saving marks the catalog changed for publish(), even when the save fails.
        edits++
        if (loadFailed) return
        val saved = obj("journalVersion" to 1, "committed" to value.data)
        if (candidate != null) saved.put("pending", candidate.data)
        store.save(saved)
    }
    private fun state(value: String) {
        if (value != mutable.value.connection) livenessAt = null
        mutable.update { val kept = value == "connected" && it.connection == "connected"
            it.copy(connection = value, liveness = it.liveness.takeIf { kept }, noTrafficSince = it.noTrafficSince.takeIf { kept }) }
        publish()
    }
    private var livenessAt: Double? = null
    private var livenessUplink = 0L
    // The downlink proves nothing: listener replies and direct routes move it while the server is gone.
    private fun uplink() = Native.call("getRuntimeMetrics").optLong("uplinkBytes")
    // The counter restarts with the core, so each reading is the next baseline.
    private fun uplinkGrew(): Boolean { val now = uplink(); return (now > livenessUplink).also { livenessUplink = now } }
    // "connected" means only that the core runs. Checks the server once after Connect, then each
    // interval while traffic leaves or the last check failed. It only reports, and says whether it probed.
    private fun liveness(catalog: Catalog, generation: Long): Boolean {
        val last = livenessAt
        if (last != null) {
            if (Automation.clock() - last < Automation.livenessInterval) return false
            if (mutable.value.liveness == "ok" && !uplinkGrew()) { livenessAt = Automation.clock(); return false }
        }
        val configured = catalog.data.optJSONObject("automation")?.objects("targets").orEmpty()
        val targets = configured.ifEmpty { Automation.livenessTargets.let { all -> (0 until all.length()).map(all::getJSONObject) } }
        val ok = targets.any { target -> runCatching { engine.probe(catalog, catalog.selected, target.copy().put("protocol", "activeProxy").put("method", "GET").put("timeout", 5)) }.isSuccess }
        check(generation)
        checked(ok)
        return true
    }
    /** Shows a check of the connected server; the traffic baseline starts after the check's own requests. */
    private fun checked(ok: Boolean) {
        if (!engine.running || mutable.value.connection != "connected") return
        livenessAt = Automation.clock(); livenessUplink = uplink()
        mutable.update { it.copy(liveness = if (ok) "ok" else "noTraffic", noTrafficSince = if (ok) null else it.noTrafficSince ?: System.currentTimeMillis()) }
        publish()
    }
    fun cancel(): Long { val generation = epoch.incrementAndGet(); Native.cancelOperations(); return generation }
    fun beginConnectionRequest(): Long { stopRequested.set(false); return cancel() }
    fun isCurrentRequest(generation: Long) = generation == epoch.get() && !stopRequested.get()
    fun requestStop() {
        stopRequested.set(true)
        cancel()
        scope.launch {
            ready.await(); mutex.withLock {
                // Only a newer Connect clears the request; the busy bar's Cancel must not drop it.
                if (!stopRequested.get()) return@withLock
                try {
                    automation.stop(); catalog.data.put("connectionIntent", false).put("automationEpisode", automation.episode())
                    // Stop remains effective even when persistence becomes unavailable.
                    runCatching { persist(catalog) }.onFailure { if (it is Exception) report(it) }
                    state("disconnecting"); engine.stop(); approval = null; state("disconnected")
                    engine.service?.finish()
                } catch (error: Exception) { state("failed"); report(error) }
            }
        }
    }
    suspend fun requestConnect(manual: Boolean = true, generation: Long = beginConnectionRequest()) = withContext(Dispatchers.IO) {
        ready.await(); mutex.withLock {
            check(generation)
            storageFailure?.let { throw AppFailure(it) }
            if (catalog.selected.isEmpty()) throw AppFailure("no_selection")
            if (catalog.settings.optBoolean("xrayTunEnabled") && VpnService.prepare(app) != null) throw AppFailure("vpn_consent_required")
            if (manual) automation.rearm(Automation.clock())
            stopRequested.set(false)
            automation.intent = true
            catalog.data.put("connectionIntent", true).put("automationEpisode", automation.episode())
            // An approval built before Connect would undo it. Connect works without the save, as Stop does.
            runCatching { persist(catalog) }.onFailure { if (it is Exception) report(it) }; revision++; state("connecting")
            try { app.startForegroundService(Intent(app, ElarniVpnService::class.java).setAction(ElarniVpnService.CONNECT).putExtra(ElarniVpnService.GENERATION, generation)) }
            catch (_: Exception) { state("failed"); throw AppFailure("foreground_start_denied") }
        }
    }
    suspend fun serviceStart(owner: ElarniVpnService, restart: Boolean, requestedGeneration: Long?, startId: Int, taken: Boolean, alwaysOn: Boolean) {
        ready.await(); mutex.withLock {
            // Enabling always-on is a newer system request than an earlier in-app Stop or revoke.
            if (requestedGeneration == null && alwaysOn) stopRequested.set(false)
            val generation = epoch.get()
            // Stop is the newest request, so the start that carried it, perhaps a Disconnect, ends the service.
            if (stopRequested.get()) { owner.finish(); return }
            if (requestedGeneration != null && requestedGeneration != generation) { owner.finish(startId); return }
            if (engine.service === owner && engine.running) { state("connected"); return }
            engine.attach(owner)
            try {
                storageFailure?.let { throw AppFailure(it) }
                if (restart && !automation.intent && !alwaysOn) { owner.finish(); return }
                // Another app took the VPN while this process was gone: as after a revoke, this app no longer wants it.
                if (taken) {
                    automation.stop(); catalog.data.put("connectionIntent", false)
                    runCatching { persist(catalog) }; revision++; report(AppFailure("vpn_revoked")); state("disconnected"); owner.finish(); return
                }
                if (catalog.selected.isEmpty()) throw AppFailure("no_selection")
                if (alwaysOn) { automation.intent = true; catalog.data.put("connectionIntent", true); edits++ }
                if (!automation.intent) { owner.finish(); return }
                // A process the system killed while paused for sleep stays paused until the screen turns on.
                if (restart && catalog.settings.optBoolean("disconnectOnSleep") && !app.getSystemService(android.os.PowerManager::class.java).isInteractive) {
                    automation.sleeping = true; state("paused"); return
                }
                start(catalog, generation)
                catalog.node(catalog.selected).put("lastSuccessAt", now()).put("lastSuccessRevision", catalog.node(catalog.selected).string("configurationRevision"))
                // Start wrote intent, assets and the success time; an approval built before them would undo them.
                // A save that fails must not undo a start that worked.
                automation.healthy(Automation.clock()); runCatching { persist(catalog) }.onFailure { if (it is Exception) report(it) }; revision++; state("connected")
            } catch (error: Exception) {
                runCatching { engine.stop(releaseTunnel = !wantsRecovery()) }
                if (generation == epoch.get()) {
                    state("failed")
                    if (error is ResourceReview) challengeResource(error, "prepareConnection", JSONObject())
                    else { report(error); automation.schedule(Automation.clock()) }
                }
                else state("disconnected")
                if (generation == epoch.get() && !wantsRecovery()) owner.finish(startId)
            }
        }
    }
    suspend fun serviceGone(owner: ElarniVpnService, revoked: Boolean) {
        if (revoked) { stopRequested.set(true); cancel() }
        ready.await(); mutex.withLock {
            if (engine.service !== owner) { owner.closeTunnel(); return }
            runCatching { engine.stop() }
            if (BuildConfig.ELARNI_RECORDING) runCatching { engine.record(false) }
            engine.detach(owner)
            if (revoked) {
                automation.stop(); catalog.data.put("connectionIntent", false)
                runCatching { persist(catalog) }; revision++; report(AppFailure("vpn_revoked"))
            }
            state("disconnected")
        }
    }
    private fun start(value: Catalog, generation: Long) {
        check(generation)
        val route = value.routeFor(value.selected)
        if (route != null) {
            if (route.mapObject("profile").objects("ManagedSources").any { !route.mapObject("lists").has(it.string("id")) }) { value.refreshManaged(route.getString("id")); edits++ }
            if (route.string("assetRevision").isEmpty()) { assets.prepare(value, route.getString("id")); edits++ }
        }
        check(generation)
        engine.start(value, keepTunnel = wantsRecovery()) { check(generation) }
    }
    private fun apply(candidate: Catalog, generation: Long): JSONObject {
        check(generation); candidate.reconcileSelection(); candidate.validate()
        if (candidate.data.mapObject("automation").optBoolean("enabled")) {
            runCatching { Automation.validate(candidate.data.getJSONObject("automation"), candidate) }.onFailure { candidate.data.getJSONObject("automation").put("enabled", false) }
        }
        val before = catalog
        // Compiling validates every server; Stop cancels the epoch and interrupts a large catalog.
        // OutOfMemoryError is no Exception; the process must outlive a catalog too large for the heap.
        try { candidate.validateNodes { check(generation) } } catch (_: OutOfMemoryError) { throw AppFailure("input_too_large") }
        val wasRunning = engine.running
        val runtimeChanged = wasRunning && (before.selected != candidate.selected || candidate.selected.isEmpty() ||
            Catalog.canonical(before.compile(before.selected, app)) != Catalog.canonical(candidate.compile(candidate.selected, app)) ||
            Catalog.canonical(Settings.runtime(before.settings)) != Catalog.canonical(Settings.runtime(candidate.settings)) ||
            before.routeFor(before.selected)?.string("assetRevision") != candidate.routeFor(candidate.selected)?.string("assetRevision"))
        // A failed start keeps its interface only for recovery to retry; without a server or recovery it just drops traffic.
        val release = !wasRunning && engine.service?.holdsTunnel == true && (candidate.selected.isEmpty() || !wantsRecovery(candidate))
        if (release && candidate.selected.isEmpty()) candidate.data.put("connectionIntent", false)
        var journal = false; var started = false
        try {
            if (runtimeChanged) {
                persist(before, candidate); journal = true
                state("connecting")
                if (candidate.selected.isEmpty()) { engine.stop(); candidate.data.put("connectionIntent", false); automation.stop() }
                else { start(candidate, generation); started = true }
            }
            check(generation)
            persist(candidate)
            catalog = candidate; revision++; approval = null
            val routingChanged = canonicalRouting(before) != canonicalRouting(candidate)
            val oldNodes = before.nodes.associateBy { it.string("id") }
            val newNodes = candidate.nodes.associateBy { it.string("id") }
            fun current(id: String, result: JSONObject): Boolean {
                val old = oldNodes[id]; val node = newNodes[id]
                return !routingChanged && old != null && node != null && old.string("configurationRevision") == node.string("configurationRevision") &&
                    old.string("ipPreference") == node.string("ipPreference") && (result.string("protocol") != "activeProxy" || before.selected == candidate.selected)
            }
            mutable.update { value -> value.copy(pings = value.pings.filter { (id, result) -> current(id, result) }, exits = value.exits.filter { (id, result) -> current(id, result) }) }
            if (runtimeChanged) state(if (engine.running) "connected" else "disconnected")
            // Removing the selected server stopped the engine; end its service and notification too.
            if (runtimeChanged && candidate.selected.isEmpty()) engine.service?.finish()
            if (release) {
                engine.stop()
                if (candidate.selected.isEmpty()) { automation.stop(); state("disconnected") }
                engine.service?.finish()
            }
            publish()
            retireAssets()
            app.scheduleRefresh(backgroundWork())
            return obj("saved" to true)
        } catch (error: Exception) {
            if (journal) {
                // Lists, geofiles and the config are prepared before the engine stops the old core, which then still serves.
                if (!started && wasRunning && engine.running) state("connected")
                else {
                    runCatching { engine.stop(releaseTunnel = !wantsRecovery()) }
                    if (epoch.get() == generation && wasRunning) {
                        try { start(before, generation); state("connected") }
                        catch (_: Exception) { state("failed") }
                    }
                    // A bare Cancel publishes no state of its own; the tunnel is down.
                    else if (!stopRequested.get()) state("failed")
                }
                runCatching { persist(before) }.onFailure { storageFailure = "storage_unavailable" }
            }
            throw error
        }
    }
    private fun canonicalRouting(value: Catalog) = Catalog.canonical(obj("settings" to Settings.runtime(value.settings), "routes" to JSONArray(value.routes.map { obj("id" to it.string("id"), "enabled" to it.optBoolean("enabled", true), "model" to it.mapObject("routeModel"), "assets" to it.string("assetRevision")) }), "assignments" to value.assignments))
    suspend fun execute(command: String, args: JSONObject = JSONObject()): JSONObject = withContext(Dispatchers.IO) {
        ready.await(); mutex.withLock {
            storageFailure?.let { throw AppFailure(it) }
            val generation = epoch.get()
            mutable.update { it.copy(busy = true) }
            try { dispatch(command, args, generation) }
            catch (error: Exception) { report(error, args.string("id").takeIf { command == "refresh" && it.isNotEmpty() }); throw AppFailure(code(error)) }
            finally { mutable.update { it.copy(busy = false) }; publish() }
        }
    }
    /** A test batch holds the lock until it ends, so while connected it runs [CONNECTED_TEST_BATCH] servers
     *  at a time with a health check between parts: a long batch can't hold failover back. */
    suspend fun ping(args: JSONObject): JSONObject {
        val ids = args.strings("ids")
        if (!engine.running || ids.size <= CONNECTED_TEST_BATCH) return execute("ping", args)
        val results = JSONArray()
        for (part in ids.chunked(CONNECTED_TEST_BATCH)) {
            val done = execute("ping", args.copy().put("ids", JSONArray(part))).getJSONArray("results")
            for (i in 0 until done.length()) results.put(done.get(i))
            tick()
        }
        return obj("results" to results)
    }
    private fun dispatch(command: String, args: JSONObject, generation: Long): JSONObject = try {
        dispatchUnchecked(command, args, generation)
    } catch (review: ResourceReview) {
        check(generation); challengeResource(review, command, args)
    }
    private fun dispatchUnchecked(command: String, args: JSONObject, generation: Long): JSONObject {
        val id = args.string("id")
        when (command) {
            "read" -> return catalog.data.copy()
            "reject" -> { approval = null; retireAssets(); return JSONObject() }
            "approveResource" -> {
                val value = approval ?: throw AppFailure("approval_expired")
                if (value.command.isEmpty() || value.token != args.string("token") || value.base != revision || value.expires < now()) throw AppFailure("approval_expired")
                val candidate = value.candidate.copy()
                val route = candidate.route(value.warning.getString("routeId"))
                route.put("approvedResources", route.mapObject("approvedResources").put(value.warning.getString("resourceURL"), value.warning.getJSONArray("chain")))
                approval = null
                try {
                    when (value.command) {
                        "refreshManaged" -> candidate.refreshManaged(value.args.getString("id"), value.args.string("sourceId"))
                        "refreshGeofiles" -> assets.prepare(candidate, value.args.getString("id"), true, value.args.string("kind"))
                        "prepareConnection" -> {
                            val target = candidate.routeFor(candidate.selected) ?: throw AppFailure("not_found")
                            if (target.mapObject("profile").objects("ManagedSources").isNotEmpty()) candidate.refreshManaged(target.getString("id"))
                            assets.prepare(candidate, target.getString("id"))
                        }
                        else -> {
                            val target = candidate.route(value.warning.getString("routeId"))
                            if (target.mapObject("profile").objects("ManagedSources").isNotEmpty()) candidate.refreshManaged(target.getString("id"))
                            assets.prepare(candidate, target.getString("id"))
                        }
                    }
                } catch (review: ResourceReview) { return challengeResource(review, value.command, value.args) }
                val result = apply(candidate, generation)
                if (value.command == "prepareConnection") result.put("reconnectAfterReview", true)
                return result
            }
            "share" -> return catalog.share(id, args.optBoolean("subscription"))
            "deviceID" -> return obj("deviceId" to catalog.deviceID(id))
            "shareLinks" -> return catalog.shareLinks(args.strings("ids"))
            "exportRouting" -> return obj("text" to catalog.route(id).getJSONObject("profile").toString(2))
            "decodeRouting" -> return Native.domain("decodeRouting", obj("content" to args.getString("text"))).getJSONObject("import")
            "exportPerApp" -> return obj("text" to Settings.perAppExport(catalog.settings.getString("perAppMode"), catalog.settings.strings("perAppProcesses"), catalog.settings.mapObject("perAppTargets")))
            "backup" -> return try { Native.call("sealCatalogBackup", obj("catalog" to catalog.backup(), "password" to args.getString("password"))) }
                // Sealing validates the catalog as a restore would; a refusal names the limits, not a bad password.
                catch (error: AppFailure) { throw if (error.code == "invalid_backup") AppFailure("backup_unsupported") else error }
            "diagnostics" -> return obj("text" to diagnostics().toString(2))
            "systemInfo" -> return systemInfo()
            "routeTable" -> return routeTable()
            "repair" -> {
                stopRequested.set(true); cancel(); automation.stop()
                catalog.data.put("connectionIntent", false).put("automationEpisode", automation.episode())
                engine.stop(); engine.service?.finish(); approval = null; state("disconnected"); persist(catalog)
                return obj("repaired" to true)
            }
            "apps" -> return installedApps()
            "ping" -> {
                val sourceId = args.string("sourceId")
                val scope = if (sourceId.isEmpty()) catalog.nodes else catalog.source(sourceId).objects("nodes")
                if (id.isNotEmpty() && scope.none { it.string("id") == id }) throw AppFailure("not_found")
                val eligible = scope.filter { it.string("format") == "xrayProfile" }.map { it.getString("id") }
                val ids = if (args.has("ids")) {
                    val requested = args.optJSONArray("ids") ?: throw AppFailure("invalid_input")
                    if ((0 until requested.length()).any { requested.get(it) !is String }) throw AppFailure("invalid_input")
                    val values = args.strings("ids")
                    if (values.size != values.distinct().size || values.any { it !in eligible }) throw AppFailure("not_found")
                    values
                } else if (id.isNotEmpty()) listOf(id) else eligible
                val results = mutableListOf<JSONObject>()
                if (ids.isEmpty()) return obj("results" to JSONArray())
                val trace = args.optBoolean("trace")
                if (trace) mutable.update { it.copy(exits = it.exits + ids.associateWith { nodeID -> obj("nodeId" to nodeID, "status" to "pending") }) }
                val workers = Executors.newFixedThreadPool(minOf(32, ids.size))
                val completed = ExecutorCompletionService<JSONObject>(workers)
                // The actor holds the catalog read-only until all workers join;
                // Engine copies disposable proxy configurations. Submit one round
                // at a time so large subscriptions cannot queue catalog copies.
                // TSPU freezes an SNI after more than 3 near-simultaneous handshakes, so at most two probes share one at a time.
                val queues = LinkedHashMap<String, ArrayDeque<String>>()
                val scoped = scope.associateBy { it.getString("id") }
                ids.forEach { queues.getOrPut(Catalog.probeKey(scoped.getValue(it)) ?: it) { ArrayDeque() }.add(it) }
                val busy = mutableMapOf<String, Int>(); val keys = mutableMapOf<String, String>()
                var running = 0
                try {
                    fun submitNext(): Boolean {
                        val key = queues.keys.firstOrNull { (busy[it] ?: 0) < 2 } ?: return false
                        val waiting = queues.getValue(key); val nodeID = waiting.removeFirst(); val options = args.copy()
                        if (waiting.isEmpty()) queues.remove(key)
                        busy[key] = (busy[key] ?: 0) + 1; keys[nodeID] = key; running++
                        completed.submit(java.util.concurrent.Callable {
                            check(generation)
                            val result = try { engine.probe(catalog, nodeID, options) }
                                catch (error: Exception) { obj("nodeId" to nodeID, "status" to "failed", "error" to code(error), "timestamp" to now()) }
                            result.put("protocol", options.string("protocol", "proxy")).put("configurationRevision", catalog.node(nodeID).string("configurationRevision", nodeID))
                        })
                        return true
                    }
                    // A cancel misses a test still being set up, so the wait checks for it; the finally block below stops what started since.
                    fun nextCompletion(): java.util.concurrent.Future<JSONObject> {
                        while (true) { completed.poll(250, TimeUnit.MILLISECONDS)?.let { return it }; check(generation) }
                    }
                    while (running < 32 && submitNext()) { }
                    repeat(ids.size) {
                        val completion = nextCompletion()
                        check(generation)
                        val result = completion.get()
                        check(generation); results.add(result)
                        val nodeID = result.getString("nodeId")
                        mutable.update { if (trace) it.copy(exits = it.exits + (nodeID to result)) else it.copy(pings = it.pings + (nodeID to result)) }
                        keys[nodeID]?.let { busy[it] = busy.getValue(it) - 1 }; running--
                        while (running < 32 && submitNext()) { }
                    }
                } finally {
                    workers.shutdownNow()
                    while (!workers.awaitTermination(1, TimeUnit.SECONDS)) { Native.cancelOperations() }
                    // A cancelled check leaves no server waiting on it.
                    if (trace) mutable.update { value -> value.copy(exits = value.exits.filterValues { it.string("status") != "pending" }) }
                }
                val byID = results.associateBy { it.getString("nodeId") }
                return obj("results" to JSONArray(ids.map { byID.getValue(it) }))
            }
        }
        val candidate = catalog.copy()
        var warning: JSONObject? = null
        when (command) {
            "import" -> warning = candidate.importText(args.getString("text"))
            "refresh" -> {
                try {
                    warning = candidate.refresh(id, format = args.string("format").takeIf(String::isNotEmpty))
                    // A failure to apply counts as a failed refresh too, so the retry delays apply.
                    if (warning == null) { check(generation); return apply(candidate, generation) }
                } catch (error: Exception) {
                    if (error is ResourceReview) throw error
                    // The candidate may hold half the update; record the failure on the applied catalog.
                    // A download that a network change cancelled did not fail; the next pass retries it.
                    check(generation); if (code(error) == "fetch_cancelled") throw error
                    val failed = catalog.copy(); failed.refreshFailed(id, code(error)); apply(failed, generation); throw error
                }
            }
            "approveSource" -> {
                val value = approval ?: throw AppFailure("approval_expired")
                if (value.token != args.string("token") || value.base != revision || value.expires < now()) throw AppFailure("approval_expired")
                approval = null
                val approved = value.candidate.copy()
                val next = approved.refresh(value.warning.getString("subscriptionId"), value.warning.getJSONArray("chain"), value.warning.string("format"))
                if (next != null) return challenge(approved, next)
                return apply(approved, generation)
            }
            "select" -> {
                if (candidate.node(id).string("format") != "xrayProfile") throw AppFailure("unsupported_profile")
                candidate.data.put("selectedNodeId", id); automation.rearm(Automation.clock())
                // The picked server becomes the primary; the allowed backups stay.
                candidate.data.optJSONObject("automation")?.takeIf { it.optBoolean("enabled") }?.let {
                    val ids = listOf(id) + if (it.string("policy") == "fixed") emptyList() else it.strings("nodeIDs").filter { other -> other != id }.take(999)
                    it.put("subscriptionID", candidate.sourceFor(id).string("id")).put("nodeIDs", JSONArray(ids))
                    if (it.has("russianEntryNodeIDs")) it.put("russianEntryNodeIDs", JSONArray(it.strings("russianEntryNodeIDs").filter(ids::contains)))
                }
            }
            "favorite" -> candidate.node(id).put("favorite", args.getBoolean("value"))
            // Refresh matches on the provider's name, so keep it beside the user's.
            "renameNode" -> candidate.node(id).let { it.put("providerName", it.string("providerName", it.string("name"))).put("name", name(args.getString("name"))) }
            "renameSource" -> {
                val source = candidate.source(id)
                val requested = args.string("name").trim()
                if (requested.isEmpty() && source.has("url")) {
                    source.remove("manualName")
                    source.put("name", source.string("providerName", source.string("importedName", java.net.URI(source.getString("url")).host)))
                } else source.put("manualName", name(requested)).put("name", name(requested))
            }
            "pinSource" -> candidate.source(id).put("pinned", args.getBoolean("value"))
            // A new random key changes this subscription's device ID only.
            "resetDeviceID" -> candidate.source(id).also { if (!it.has("url")) throw AppFailure("invalid_input") }.put("deviceSalt", newId())
            "deleteNode", "deleteNodes" -> {
                val ids = if (command == "deleteNode") listOf(id) else {
                    val requested = args.optJSONArray("ids") ?: throw AppFailure("invalid_input")
                    if ((0 until requested.length()).any { requested.get(it) !is String }) throw AppFailure("invalid_input")
                    // As on the desktop: all or none, and the selected server stays.
                    args.strings("ids").also { if (it.isEmpty() || it.size != it.distinct().size || candidate.selected in it) throw AppFailure("invalid_input") }
                }
                ids.forEach { nodeID ->
                    val source = candidate.sourceFor(nodeID)
                    // A provider's server is hidden instead, so that its refresh keeps it out.
                    if (source.has("url")) source.put("hiddenNodes", JSONArray(source.objects("hiddenNodes") + candidate.node(nodeID)))
                    source.put("nodes", JSONArray(source.objects("nodes").filter { it.string("id") != nodeID }))
                }
            }
            "showNode" -> {
                val source = candidate.sources.firstOrNull { it.objects("hiddenNodes").any { node -> node.string("id") == id } } ?: throw AppFailure("not_found")
                val (shown, hidden) = source.objects("hiddenNodes").partition { it.string("id") == id }
                source.put("hiddenNodes", JSONArray(hidden)).put("nodes", JSONArray(source.objects("nodes") + shown))
            }
            "deleteSource" -> {
                candidate.source(id)
                candidate.data.put("subscriptions", JSONArray(candidate.sources.filter { it.string("id") != id }))
                candidate.assignments.remove(id)
                val removed = candidate.routes.filter { it.string("providerSubscriptionId") == id }.map { it.string("id") }.toSet()
                candidate.data.put("profiles", JSONArray(candidate.routes.filter { it.string("id") !in removed }))
                candidate.assignments.keys().asSequence().toList().filter { candidate.assignments.string(it) in removed }.forEach(candidate.assignments::remove)
            }
            "sourceOptions" -> {
                val options = args.getJSONObject("options")
                val source = candidate.source(id)
                if (options.has("refreshHours") && !Catalog.validRefreshHours.matches(options.string("refreshHours"))) throw AppFailure("invalid_settings")
                Native.call("validateSubscriptionFetchOptions", obj("url" to source.getString("url")).merge(options.copy().apply { remove("refreshHours") }))
                source.put("fetchOptions", options)
                val fallback = args.strings("fallbackHosts")
                if (fallback.size > 8 || fallback.any { Catalog.safeURL("https://$it/") == null || java.net.URI("https://$it/").host != it }) throw AppFailure("invalid_target")
                source.put("fallbackHosts", JSONArray(fallback))
            }
            "group" -> candidate.selectGroup(id, args.getString("group"), args.getString("choice"))
            "nodeIP" -> {
                if (args.getString("value") !in listOf("inherit", "automatic", "ipv4", "ipv6")) throw AppFailure("invalid_settings")
                if (args.getString("value") == "inherit") candidate.node(id).remove("ipPreference") else candidate.node(id).put("ipPreference", args.getString("value"))
            }
            "settings" -> {
                // Requiring a login without a saved one generates it, as on a fresh install.
                if (args.getJSONObject("settings").optBoolean("inboundAuthEnabled") && candidate.data.optJSONObject("inboundCredentials") == null)
                    candidate.data.put("inboundCredentials", Catalog.generatedLogin())
                candidate.data.put("settings", Settings.normalize(candidate.settings.merge(args.getJSONObject("settings")), candidate.data.optJSONObject("inboundCredentials")))
                candidate.ensureControlKey()
            }
            // Apps that hold the old key stop working until they get this one.
            "newControlKey" -> candidate.data.put("externalControlKey", RemoteControl.newKey())
            "credentials" -> {
                val user = args.getString("username"); val password = args.getString("password")
                if (user.toByteArray().size !in 1..255 || password.toByteArray().size !in 1..255 || (user + password).any(Char::isISOControl) || ':' in user) throw AppFailure("invalid_settings")
                candidate.data.put("inboundCredentials", obj("username" to user, "password" to password))
            }
            "automation" -> {
                val config = args.getJSONObject("configuration")
                Automation.validate(config, candidate); candidate.data.put("automation", config); automation.rearm(Automation.clock())
            }
            "importPerApp" -> {
                val value = Settings.perAppProfile(args.getString("text"))
                candidate.data.put("settings", Settings.normalize(candidate.settings.put("perAppMode", value.getString("mode")).put("perAppProcesses", value.getJSONArray("processes")).put("perAppTargets", value.optJSONObject("targets") ?: JSONObject()).put("xrayTunEnabled", true), candidate.data.optJSONObject("inboundCredentials")))
            }
            "saveRouting" -> { candidate.importRouting(args.getString("text"), update = id.takeIf(String::isNotEmpty)) }
            "duplicateRouting" -> {
                val profile = candidate.route(id).getJSONObject("profile").copy()
                val base = profile.string("Name", "Routing profile") + " copy"
                var title = base; var suffix = 2
                while (candidate.routes.any { it.string("name") == title }) title = "$base ${suffix++}"
                candidate.importRouting(profile.put("Name", title).toString(), forceNew = true)
            }
            "assignRouting" -> {
                val route = args.string("routeId")
                if (route.isNotEmpty()) candidate.route(route)
                candidate.assignRouting(id, route.ifEmpty { null })
            }
            "enableRouting" -> candidate.route(id).put("enabled", args.getBoolean("value"))
            "resetRouting" -> { val original = candidate.route(id).getJSONObject("original").toString(); candidate.importRouting(original, update = id); candidate.route(id).put("edited", false) }
            "deleteRouting" -> {
                candidate.route(id); candidate.data.put("profiles", JSONArray(candidate.routes.filter { it.string("id") != id }))
                candidate.assignments.keys().asSequence().toList().filter { candidate.assignments.string(it) == id }.forEach(candidate.assignments::remove)
            }
            "refreshManaged" -> candidate.refreshManaged(id, args.string("sourceId"))
            "refreshGeofiles" -> assets.prepare(candidate, id, refresh = true, only = args.string("kind"))
            "restore" -> {
                // A restore clears the connection intent, which a running VPN would then outlive; as on desktop, disconnect first.
                if (mutable.value.connection in listOf("connected", "connecting", "paused", "disconnecting")) throw AppFailure("disconnect_first")
                val backup = Native.call("openCatalogBackup", obj("text" to args.getString("text"), "password" to args.getString("password"))).getJSONObject("catalog")
                Native.call("validateCatalogBackup", obj("catalog" to backup))
                candidate.restoreBackup(backup)
            }
            else -> throw AppFailure("unsupported_operation")
        }
        check(generation)
        if (warning != null) return challenge(candidate, warning)
        return apply(candidate, generation)
    }
    private fun challenge(candidate: Catalog, warning: JSONObject): JSONObject {
        val token = newId(); warning.put("token", token)
        approval = Approval(token, revision, now() + 300, candidate, warning)
        publish(); return obj("warning" to warning)
    }
    private fun challengeResource(review: ResourceReview, command: String, args: JSONObject): JSONObject {
        val token = newId()
        val warning = review.warning.copy().put("token", token).put("mode", "resource").put("routeId", review.routeID).put("resourceURL", review.url)
        approval = Approval(token, revision, now() + 300, review.catalog.copy(), warning, command, args.copy())
        publish(); return obj("warning" to warning)
    }
    private fun name(text: String) = text.trim().takeIf { it.isNotEmpty() && it.length <= 1024 && it.none(Char::isISOControl) } ?: throw AppFailure("invalid_input")
    private fun installedApps(): JSONObject {
        val networkApps = app.packageManager.getInstalledApplications(0).filter {
            app.packageManager.checkPermission(android.Manifest.permission.INTERNET, it.packageName) == PackageManager.PERMISSION_GRANTED
        }
        val selected = catalog.settings.strings("perAppProcesses").mapNotNull { runCatching { app.packageManager.getApplicationInfo(it, 0) }.getOrNull() }
        return obj("apps" to JSONArray((networkApps + selected).distinctBy { it.packageName }.filter { it.packageName != app.packageName }.map {
            obj("package" to it.packageName, "name" to app.packageManager.getApplicationLabel(it).toString(), "uid" to it.uid)
        }.sortedBy { it.string("name").lowercase() }))
    }
    private fun diagnostics() = obj("version" to 1, "appVersion" to BuildConfig.VERSION_NAME, "platform" to "android", "sdk" to Build.VERSION.SDK_INT,
        "core" to Native.call("xrayVersion").string("version"), "connection" to mutable.value.connection, "error" to mutable.value.error,
        "sourceCount" to catalog.sources.size, "nodeCount" to catalog.nodes.size, "routingCount" to catalog.routes.size,
        "systemVPN" to catalog.settings.optBoolean("xrayTunEnabled"), "perAppMode" to catalog.settings.string("perAppMode"),
        "metrics" to mutable.value.metrics, "automation" to automation.status, "recentIssues" to JSONArray(mutable.value.issues))
    private fun systemInfo() = obj("platform" to "Android ${Build.VERSION.RELEASE}", "sdk" to Build.VERSION.SDK_INT, "device" to "${Build.MANUFACTURER} ${Build.MODEL}",
        "abis" to JSONArray(Build.SUPPORTED_ABIS.toList()), "cores" to Runtime.getRuntime().availableProcessors(), "app" to BuildConfig.VERSION_NAME,
        "core" to Native.call("xrayVersion").string("version"), "vpnConsent" to vpnConsented(app),
        "alwaysOn" to (engine.service?.isAlwaysOn == true), "lockdown" to (engine.service?.isLockdownEnabled == true), "networkAvailable" to (engine.physical() != null))
    private fun routeTable(): JSONObject {
        val connectivity = app.getSystemService(android.net.ConnectivityManager::class.java)
        return obj("networks" to JSONArray(connectivity.allNetworks.mapNotNull { network ->
            val links = connectivity.getLinkProperties(network) ?: return@mapNotNull null
            obj("interface" to links.interfaceName, "vpn" to (connectivity.getNetworkCapabilities(network)?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) == true),
                "routes" to JSONArray(links.routes.map { obj("destination" to it.destination.toString(), "gateway" to (it.gateway?.hostAddress ?: "")) }), "dns" to JSONArray(links.dnsServers.map { it.hostAddress }))
        }))
    }
    private fun wantsRecovery(value: Catalog = catalog) = automation.intent && (value.settings.optBoolean("onDemandEnabled") || value.data.mapObject("automation").optBoolean("enabled"))
    suspend fun networkChanged() {
        ready.await(); mutex.withLock {
            // Callbacks can wait behind a connection transaction and arrive out
            // of order. Read the current physical path under the same owner;
            // an old snapshot must not restart a newly connected tunnel.
            val connectivity = app.getSystemService(android.net.ConnectivityManager::class.java)
            val networks = connectivity.allNetworks.filter {
                connectivity.getNetworkCapabilities(it)?.let { capabilities ->
                    capabilities.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                        capabilities.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                } == true
            }
            val physical = engine.physical()
            val signature = "${physical?.networkHandle ?: 0}:" + networks.map { it.networkHandle }.sorted().joinToString(",")
            val available = networks.isNotEmpty()
            automation.path(signature, available, Automation.clock())
            // The VPN's underlying network is the default one, which Android tracks itself: the core binds no socket.
            // New sockets follow the default network, and the default-network callback tells the core's pooled ones
            // to move. A restart resets every tunneled connection, so only a network that is gone takes one. The new
            // default often comes before the old network leaves the list; that later loss calls here again.
            // An open approval does not hold recovery back; it gates only its own candidate.
            if (engine.running && physical != engine.network && engine.network !in networks && available && wantsRecovery() && !automation.sleeping)
                restart(epoch.get())
            publish()
        }
    }
    /** Restarts the core on the current network; a Disconnect or Cancel meanwhile is no failure. */
    private fun restart(generation: Long) {
        try { state("connecting"); start(catalog, generation); automation.healthy(Automation.clock()); state("connected") }
        catch (error: Exception) { if (code(error) != "cancelled") { state("failed"); automation.schedule(Automation.clock()); report(error) } }
    }
    suspend fun screenChanged(sleeping: Boolean) {
        ready.await(); mutex.withLock {
            if (!catalog.settings.optBoolean("disconnectOnSleep")) return
            automation.sleeping = sleeping
            if (sleeping && engine.running) { try { engine.stop() } finally { state("paused") } }
            if (!sleeping && automation.intent) { automation.rearm(Automation.clock()); automation.schedule(Automation.clock()) }
        }
    }
    suspend fun boot() {
        ready.await()
        if (catalog.settings.optBoolean("launchAtBoot") && catalog.selected.isNotEmpty()) {
            try { requestConnect(false) } catch (error: Exception) { report(error) }
        }
    }
    suspend fun tick() {
        ready.await(); if (!mutex.tryLock()) return
        try {
            // An approval gates only applying its candidate; recovery keeps running on the applied catalog.
            if (storageFailure != null || stopRequested.get()) return
            val time = Automation.clock(); val generation = epoch.get()
            val config = catalog.data.optJSONObject("automation") ?: Automation.defaults()
            var probed = false
            if (engine.running) {
                if (!Native.call("getXrayState").optBoolean("running")) { try { engine.stop(releaseTunnel = !wantsRecovery()) } finally { state("failed") } }
                else if (catalog.settings.optBoolean("monitoringEnabled") && app.getSystemService(android.os.PowerManager::class.java).isInteractive || Widgets.shown(app)) {
                    // A widget alone reads the counters for its speed line; the app shows them only with monitoring on, and only on screen.
                    val metrics = Native.call("getRuntimeMetrics")
                    if (catalog.settings.optBoolean("monitoringEnabled")) mutable.update { it.copy(metrics = metrics) }
                    Widgets.traffic(app, metrics, mutable.value)
                }
                // With failover on, its health check stands in for liveness after the first check: one probe a tick, none offline.
                if (engine.running && mutable.value.connection == "connected" && automation.online && (livenessAt == null || !config.optBoolean("enabled")))
                    probed = liveness(catalog, generation)
            }
            if (automation.intent && !automation.sleeping && (wantsRecovery() || mutable.value.connection == "paused")) {
                automation.unattended(time)
                val targets = config.objects("targets")
                var healthy = engine.running
                if (config.optBoolean("enabled") && engine.running && automation.online && !probed &&
                    automation.healthDue(time, mutable.value.liveness == "ok") { uplinkGrew() }) {
                    // As on desktop and macOS, one passing target keeps the server.
                    healthy = targets.any { target -> runCatching { engine.probe(catalog, catalog.selected, target.copy().put("protocol", "activeProxy").put("method", "GET").put("timeout", 5)) }.isSuccess }
                    check(generation)
                    checked(healthy)
                    val russian = config.strings("russianEntryNodeIDs").toSet()
                    automation.observe(catalog.selected, healthy, catalog.selected in russian)
                    if (healthy) automation.healthy(time) else { automation.failures++; automation.healthAt = time + Automation.healthInterval }
                    val optimize = healthy && config.string("policy") == "lowestLatency" && time - automation.lastOptimization >= 300
                    if (optimize || !healthy && automation.failures >= 3) {
                        val scores = mutableMapOf<String, Double>()
                        val order = config.strings("nodeIDs").let { ids -> if (healthy) ids else automation.recoveryOrder(ids, catalog.selected,
                            ids.filter { id -> runCatching { Automation.tcp443(catalog.node(id).mapObject("config")) }.getOrDefault(false) }.toSet(), russian) }
                        automation.round(order, catalog.selected, time).forEach { id ->
                            check(generation)
                            // Like the health check, a candidate qualifies on the targets that answer.
                            val values = targets.mapNotNull { runCatching { engine.probe(catalog, id, it.copy().put("protocol", "proxy").put("method", "GET").put("timeout", 5)).getDouble("latencyMs") }.getOrNull() }
                            automation.observe(id, values.isNotEmpty(), id in russian)
                            if (values.isEmpty()) automation.cooldown[id] = time + 60 else scores[id] = values.average()
                        }
                        val chosen = automation.choose(config.string("policy"), order, catalog.selected, scores, healthy, time)
                        if (chosen != null && chosen != catalog.selected) {
                            val candidate = catalog.copy(); candidate.data.put("selectedNodeId", chosen)
                            apply(candidate, generation); automation.lastSwitch = time; automation.healthy(time); healthy = true
                        }
                        automation.lastOptimization = time
                    }
                }
                if (!healthy && (!engine.running || automation.failures >= 3)) automation.schedule(time)
                if (automation.begin(time)) {
                    // A failed save must not hold the retry back.
                    catalog.data.put("automationEpisode", automation.episode()); runCatching { persist(catalog) }.onFailure { if (it is Exception) report(it) }
                    try { state("connecting"); start(catalog, generation); automation.healthy(Automation.clock()); state("connected") }
                    catch (error: Exception) { check(generation); state("failed"); automation.schedule(Automation.clock()) }
                }
            }
            // Publishing compares the whole catalog; the tick has only automation news to publish.
            val episode = automation.episode()
            if (Catalog.canonical(episode) != Catalog.canonical(catalog.data.opt("automationEpisode")) || automation.status != mutable.value.automationStatus ||
                automation.whitelist != mutable.value.whitelistMode) {
                catalog.data.put("automationEpisode", episode); edits++; publish()
            }
        } catch (error: Exception) { if (code(error) != "cancelled") report(error) }
        finally { mutex.unlock() }
    }
    /** The refresh job [wait]s for the lock; a pass the 2 s tick or an action holds back would be its only run. */
    suspend fun maintenance(time: Double = now(), wait: Boolean = false) {
        ready.await()
        if (wait) mutex.lock() else if (!mutex.tryLock()) return
        val generation = epoch.get()
        try {
            // Turning lockdown on while connected blocks the apps a split tunnel leaves out, until the tunnel is built again.
            if (engine.running && engine.service?.let { it.splitsApps && it.isLockdownEnabled } == true) restart(generation)
            // An unanswered approval lapses like a rejection, so background refresh resumes.
            if (approval?.let { it.expires < time } == true) approval = null
            if (storageFailure != null || approval != null) return
            for (source in catalog.sources) {
                check(generation)
                val at = catalog.nextRefresh(source) ?: continue
                val id = source.getString("id")
                if (at > time || (approvalBackoff["refresh $id"] ?: 0.0) > time) continue
                // A failed refresh, applying it included, records its own retry delay.
                try { dispatch("refresh", obj("id" to id), generation) }
                catch (_: Exception) { check(generation) }
                // As for routes: the review stays only on its candidate, so the applied source is still due.
                if (approval != null) { approvalBackoff["refresh $id"] = time + 7200; break }
            }
            if (approval == null) for (id in catalog.routes.map { it.getString("id") }) {
                check(generation)
                // An earlier refresh may have replaced the catalog; read and record on the current one.
                fun route() = catalog.routes.firstOrNull { it.string("id") == id }
                for ((command, next, error, count) in listOf(listOf("refreshManaged", "nextManagedRefreshAt", "managedError", "managedFailures"),
                    listOf("refreshGeofiles", "nextGeoRefreshAt", "geofileError", "geoFailures"))) {
                    if (route()?.let { !it.isNull(next) && it.optDouble(next) <= time } != true || (approvalBackoff["$command $id"] ?: 0.0) > time) continue
                    try { dispatch(command, obj("id" to id), generation) }
                    catch (failure: Exception) {
                        // A Cancel or Stop ends the pass, and a network change only its download; neither failed.
                        check(generation)
                        if (code(failure) == "fetch_cancelled") continue
                        route()?.let {
                            val failures = it.optInt(count) + 1
                            it.put(error, code(failure)).put(count, failures).put(next, now() + Catalog.retryDelay(failures)); persist(catalog)
                        }
                    }
                    // An approval waits for the user; even once it lapses, the other routes go first for two hours.
                    if (approval != null) approvalBackoff["$command $id"] = time + 7200
                    // Another refresh that applies would clear the approval before the user sees it.
                    if (approval != null) break
                }
                if (approval != null) break
            }
            if (catalog.settings.optBoolean("expiryReminders")) app.expiryNotification(catalog.sources)
            if (approval != null) app.approvalNotification()
        } catch (error: Exception) { if (code(error) != "cancelled") report(error) }
        finally { publish(); mutex.unlock() }
    }
}
