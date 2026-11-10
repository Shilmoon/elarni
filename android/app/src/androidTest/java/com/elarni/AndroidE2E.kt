package com.elarni

import android.content.Intent
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.core.content.FileProvider
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import org.junit.runners.MethodSorters
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.security.KeyStore
import java.util.concurrent.Executors

// The empty catalog's backup, taken by the first test's setup; tests share one process.
private var emptyBackup: String? = null
private const val EMPTY_BACKUP_PASSWORD = "synthetic empty catalog"

/** Runs the production UI, Rust/Go APIs, Keystore and catalog on an isolated emulator. */
@FixMethodOrder(MethodSorters.NAME_ASCENDING)
class AndroidE2E {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()
    private val repo get() = ui.activity.repository
    private fun call(command: String, args: JSONObject = JSONObject()) = runBlocking { repo.execute(command, args) }
    private fun snapshot() = Catalog(call("read"))
    private fun link(name: String = "Synthetic Android server", port: Int = 18080) = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:$port?encryption=none&security=none&type=tcp#${name.replace(" ", "%20")}"
    @Before fun isolate() {
        assertTrue("Only the task's debug application may be tested", BuildConfig.DEBUG && ui.activity.packageName == "com.elarni.debug")
        assertTrue("Live tests require an emulator", android.os.Build.FINGERPRINT.contains("generic") || android.os.Build.MODEL.contains("sdk_gphone"))
        ui.waitUntil(10_000) { !repo.state.value.loading }
        repo.requestStop()
        ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
        call("reject")
        // Each delete rewrites the whole catalog: the hundreds of profiles a limit test leaves took the next test's setup
        // a minute or two. Restoring the empty catalog's backup clears them in one change.
        val left = snapshot().let { it.sources.size + it.routes.size }
        emptyBackup?.let { if (left > 8) call("restore", obj("text" to it, "password" to EMPTY_BACKUP_PASSWORD)) }
        snapshot().sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        snapshot().routes.forEach { call("deleteRouting", obj("id" to it.getString("id"))) }
        call("settings", obj("settings" to Settings.defaults()))
        if (emptyBackup == null) emptyBackup = call("backup", obj("password" to EMPTY_BACKUP_PASSWORD)).getString("text")
    }
    @After fun stop() { repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" } }

    @Test fun a_uiImportQRAndEncryptedRestart() {
        ui.runOnIdle { ui.activity.copy(link()) }
        ui.onNodeWithContentDescription("Import profiles").performClick()
        ui.onNodeWithText("Import from clipboard").performClick()
        ui.waitUntil(10_000) { snapshot().nodes.size == 1 }
        ui.waitUntil(5000) { ui.onAllNodes(hasScrollToIndexAction()).fetchSemanticsNodes().isNotEmpty() }
        ui.waitUntil(5000) { snapshot().selected.isNotEmpty() }
        val catalog = snapshot(); val node = catalog.nodes.single()
        call("favorite", obj("id" to node.getString("id"), "value" to true))
        val share = call("share", obj("id" to node.getString("id")))
        val png = Base64.decode(share.getString("png"), Base64.DEFAULT)
        assertEquals(share.getString("text"), Native.qr(png))
        val privateFile = File(ui.activity.noBackupFilesDir, "catalog.v1.enc").readBytes()
        assertFalse(String(privateFile, Charsets.ISO_8859_1).contains("00000000-0000-4000-8000-000000000001"))
        assertFalse(String(privateFile, Charsets.ISO_8859_1).contains("Synthetic Android"))
        val saved = Catalog(EncryptedStore(ui.activity).load()!!.getJSONObject("committed"))
        assertEquals(node.getString("id"), saved.selected)
        assertTrue(saved.node(saved.selected).getBoolean("favorite"))
        ui.activityRule.scenario.recreate()
        ui.waitUntil(5000) { !repo.state.value.loading }
        ui.onAllNodesWithText("Synthetic Android server").assertAny(hasText("Synthetic Android server"))
        val file = File(ui.activity.cacheDir, "shared").apply { mkdirs() }.resolve("e2e-qr.png").apply { writeBytes(png) }
        val uri = FileProvider.getUriForFile(ui.activity, "com.elarni.debug.files", file)
        val launchIntent = Intent(ui.activity.intent)
        // A local import skips a server it already has, so the shared QR goes into an empty catalog.
        call("deleteSource", obj("id" to catalog.sources.single().getString("id")))
        ui.activity.runOnUiThread { ui.activity.startActivity(Intent(ui.activity, MainActivity::class.java).setAction(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, uri)) }
        ui.waitUntil(10_000) { snapshot().nodes.map { it.string("name") } == listOf("Synthetic Android server") }
        assertNull(ui.activity.interaction.incoming)
        ui.onNodeWithText("Link or configuration").assertDoesNotExist()
        // ActivityScenario filters teardown callbacks by the launch Intent. The real
        // share intent was handled and asserted above; restore only its test identity.
        ui.runOnUiThread { ui.activity.intent = launchIntent }
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
    }

    @Test fun b_subscriptionRefreshesAndAtomicValidation() {
        HTTPFixture().use { feed ->
            feed.body = link("Provider one")
            feed.headers = mapOf("profile-title" to "Synthetic provider", "subscription-userinfo" to "upload=10; download=20; total=1000; expire=2000000000")
            val warning = call("import", obj("text" to feed.url)).getJSONObject("warning")
            assertEquals(0, snapshot().sources.size)
            call("approveSource", obj("token" to warning.getString("token")))
            val original = snapshot(); val source = original.sources.single(); val id = source.getString("id")
            assertEquals("Synthetic provider", source.getString("name"))
            assertEquals(20, source.getJSONObject("metadata").getInt("download"))
            call("select", obj("id" to original.nodes.single().getString("id")))
            // Manual and background refreshes apply the provider's change at once.
            feed.body = link("Provider one", 18082)
            call("refresh", obj("id" to id))
            assertEquals(18082, endpointPort(snapshot()))
            val due = snapshot().source(id).getDouble("nextRefreshAt")
            val requests = feed.requests.get()
            feed.body = link("Provider one", 18083)
            ui.waitUntil(10_000) { runBlocking { repo.maintenance(due) }; feed.requests.get() > requests }
            assertEquals(18083, endpointPort(snapshot()))
            feed.body = link("Provider one", 18081)
            call("refresh", obj("id" to id))
            assertEquals(18081, endpointPort(snapshot()))
            feed.body = link("Valid") + "\nnot-a-supported-profile"
            expectFailure { call("refresh", obj("id" to id)) }
            assertEquals(1, snapshot().nodes.size)
            assertEquals(18081, endpointPort(snapshot()))
            call("renameSource", obj("id" to id, "name" to "Custom name"))
            feed.body = link("Provider one", 18081)
            feed.headers = mapOf("profile-title" to "New provider title")
            call("refresh", obj("id" to id))
            assertEquals("Custom name", snapshot().source(id).string("name"))
            call("renameSource", obj("id" to id, "name" to ""))
            assertEquals("New provider title", snapshot().source(id).string("name"))
            assertFalse(snapshot().source(id).has("manualName"))
            feed.headers = mapOf("profile-title" to "Following provider title")
            call("refresh", obj("id" to id))
            assertEquals("Following provider title", snapshot().source(id).string("name"))
            feed.body = link("Provider one", 18081); feed.headers = mapOf("hide-url" to "true")
            call("refresh", obj("id" to id))
            assertEquals("sharing_disabled", expectFailure { call("share", obj("id" to id, "subscription" to true)) })
        }
    }

    @Test fun c_routingGroupsBackupsAndWrongPassword() {
        call("import", obj("text" to link()))
        val id = snapshot().nodes.single().getString("id")
        call("select", obj("id" to id))
        val profile = obj("Name" to "Synthetic routing", "DomainStrategy" to "IPOnDemand", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8", "DirectSites" to JSONArray(listOf("domain:example.test")), "BlockIp" to JSONArray(listOf("192.0.2.0/24")))
        val encoded = android.util.Base64.encodeToString(profile.toString().toByteArray(), android.util.Base64.NO_WRAP)
        call("import", obj("text" to "elarni://routing/add/$encoded"))
        val route = snapshot().routes.single().getString("id")
        assertEquals(0, snapshot().assignments.length())
        call("assignRouting", obj("id" to snapshot().sources.single().getString("id"), "routeId" to route))
        val compiled = snapshot().compile(id, ui.activity)
        assertEquals("IPOnDemand", compiled.getJSONObject("routing").getString("domainStrategy"))
        assertTrue(compiled.getJSONObject("routing").getJSONArray("rules").toString().contains("example.test"))
        val backup = call("backup", obj("password" to "synthetic password only")).getString("text")
        assertFalse(backup.contains("example.test"))
        assertEquals("invalid_backup", expectFailure { call("restore", obj("text" to backup, "password" to "wrong password only")) })
        val before = snapshot().selected
        call("restore", obj("text" to backup, "password" to "synthetic password only"))
        assertNotEquals(before, snapshot().selected)
        assertEquals(1, snapshot().sources.size); assertEquals(1, snapshot().routes.size)
        assertEquals(1, snapshot().assignments.length())
        assertFalse(snapshot().data.optBoolean("connectionIntent"))
        val export = call("exportRouting", obj("id" to snapshot().routes.single().getString("id"))).getString("text")
        assertEquals("Synthetic routing", JSONObject(export).getString("Name"))
    }

    @Test fun e_tuicCatalogShareBackupAndAtomicRestore() {
        val link = "tuic://00000000-0000-4000-8000-000000000001:p%40ss%3A%E2%9C%93@[::1]:443?sni=tuic.example&udp_relay_mode=quic#TUIC%20fixture"
        call("import", obj("text" to link))
        val id = snapshot().nodes.single().getString("id")
        call("select", obj("id" to id))
        val compiled = snapshot().compile(id, ui.activity)
        assertTrue(compiled.getJSONArray("outbounds").toString().contains("tuic"))
        val share = call("share", obj("id" to id))
        assertEquals(share.getString("text"), Native.qr(Base64.decode(share.getString("png"), Base64.DEFAULT)))
        assertEquals("p@ss:✓", snapshot().node(id).getJSONObject("config").objects("outbounds").first().getJSONObject("settings").getString("password"))
        val revision = snapshot().node(id).string("configurationRevision")
        ui.activityRule.scenario.recreate()
        ui.waitUntil(5000) { !repo.state.value.loading }
        assertEquals(id, snapshot().selected)
        assertEquals(revision, snapshot().node(id).string("configurationRevision"))
        val backup = call("backup", obj("password" to "synthetic backup password")).getString("text")
        assertFalse(backup.contains("p@ss"))
        call("restore", obj("text" to backup, "password" to "synthetic backup password"))
        val before = snapshot().data.toString()
        val invalid = snapshot().backup()
        invalid.objects("subscriptions").single().objects("nodes").single().getJSONObject("config").objects("outbounds").first().getJSONObject("settings").remove("uuid")
        val sealed = sealByHand(invalid, "synthetic backup password")
        assertEquals("invalid_backup", expectFailure { call("restore", obj("text" to sealed, "password" to "synthetic backup password")) })
        assertEquals(before, snapshot().data.toString())
    }

    @Test fun d_settingsPerAppAndDiagnostics() {
        call("import", obj("text" to link()))
        call("select", obj("id" to snapshot().nodes.single().getString("id")))
        val apps = call("apps").objects("apps")
        assertTrue(apps.isNotEmpty())
        val selected = apps.first().getString("package")
        call("settings", obj("settings" to obj("perAppMode" to "bypass", "perAppProcesses" to JSONArray(listOf(selected)))))
        val export = JSONObject(call("exportPerApp").getString("text"))
        assertEquals("android", export.getString("platform"))
        for (bad in listOf(export.copy().put("version", 1.5), export.copy().put("version", "1"), export.copy().put("processes", JSONArray(listOf(42))), export.copy().put("extra", true))) {
            assertEquals("invalid_per_app", expectFailure { call("importPerApp", obj("text" to bad.toString())) })
        }
        assertEquals("invalid_settings", expectFailure { call("settings", obj("settings" to obj("schemaVersion" to 1.5))) })
        assertEquals("invalid_settings", expectFailure { call("settings", obj("settings" to obj("includedRoutes" to "0.0.0.0/0"))) })
        export.put("platform", "windows")
        assertEquals("invalid_per_app", expectFailure { call("importPerApp", obj("text" to export.toString())) })
        assertEquals("bypass", snapshot().settings.getString("perAppMode"))
        val routes = snapshot().settings.put("includedRoutes", JSONArray(listOf("0.0.0.0/0", "::/0"))).put("excludedRoutes", JSONArray(listOf("10.0.0.0/8", "fc00::/7")))
        call("settings", obj("settings" to routes))
        assertFalse(Cidr.routes(snapshot().settings).any { it.toString() == "0.0.0.0/0" })
        // LAN discovery stays on the physical network, unless lockdown keeps everything in the tunnel.
        val discovery = listOf("224.0.0.251", "239.255.255.250", "255.255.255.255", "ff02::fb").map(java.net.InetAddress::getByName)
        val unicast = listOf("8.8.8.8", "203.0.113.9", "255.255.255.254", "2001:db8::1").map(java.net.InetAddress::getByName)
        val open = Cidr.routes(snapshot().settings)
        assertTrue(discovery.none { address -> open.any { address in it } } && unicast.all { address -> open.any { address in it } })
        val locked = Cidr.routes(snapshot().settings, keepDiscovery = true)
        assertTrue((discovery + unicast).all { address -> locked.any { address in it } })
        val diagnostic = call("diagnostics").getString("text")
        assertFalse(diagnostic.contains("127.0.0.1")); assertFalse(diagnostic.contains("00000000-0000-4000-8000-000000000001")); assertFalse(diagnostic.contains(selected))
        call("settings", obj("settings" to obj("perAppMode" to "off")))
        assertEquals("inbound_credentials_required", expectFailure { call("settings", obj("settings" to obj("allowLAN" to true))) })
    }

    @Test fun e_keystoreTamperAndKeyLoss() {
        val context = ui.activity
        val name = "e2e-${System.nanoTime()}"
        val store = EncryptedStore(context, name)
        val original = obj("secret" to "synthetic storage marker")
        store.save(original)
        assertEquals(original.toString(), store.load().toString())
        val file = File(context.noBackupFilesDir, "$name.v1.enc")
        val good = file.readBytes(); val bad = good.clone(); bad[bad.lastIndex] = (bad.last().toInt() xor 1).toByte()
        file.writeBytes(bad)
        assertEquals("storage_corrupt", expectFailure { store.load() })
        file.writeBytes(good)
        val keys = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        keys.deleteEntry("${context.packageName}.$name.v1")
        assertEquals("storage_locked", expectFailure { store.load() })
        assertTrue(file.readBytes().contentEquals(good))
        file.delete()
    }
    @Test fun e_stopAfterFailedLoadKeepsStoredData() {
        val store = EncryptedStore(ui.activity)
        val original = store.load()!!
        store.save(obj("journalVersion" to 2, "committed" to original.getJSONObject("committed")))
        val failed = Repository(ui.activity.application as ElarniApplication)
        try {
            runBlocking { failed.awaitReady() }
            assertEquals("storage_corrupt", failed.state.value.error)
            failed.requestStop()
            // Stop publishes the cleared intent once its save has run.
            ui.waitUntil(10_000) { failed.state.value.catalog.has("connectionIntent") }
            assertEquals("Stop replaced data that failed to load", 2, store.load()!!.optInt("journalVersion"))
        } finally {
            failed.scope.cancel()
            store.save(original)
        }
    }
    @Test fun e_disconnectBeforeServiceStartEndsTheService() {
        HTTPFixture().use { feed ->
            feed.body = link()
            val id = subscribe(feed)
            val manager = allowNotifications()
            // A stalled refresh holds the catalog lock, so Disconnect arrives before the service's start runs.
            feed.stall = 10_000
            val requests = feed.requests.get()
            val refresh = Executors.newSingleThreadExecutor().submit<String> {
                try { call("refresh", obj("id" to id)); "completed" } catch (error: AppFailure) { error.code }
            }
            ui.waitUntil(10_000) { feed.requests.get() > requests }
            ui.runOnUiThread {
                ui.activity.startForegroundService(Intent(ui.activity, ElarniVpnService::class.java).setAction(ElarniVpnService.CONNECT))
                ui.activity.startService(Intent(ui.activity, ElarniVpnService::class.java).setAction(ElarniVpnService.DISCONNECT))
            }
            refresh.get(15, java.util.concurrent.TimeUnit.SECONDS)
            val deadline = System.currentTimeMillis() + 10_000
            while (manager.activeNotifications.any { it.id == 1 } && System.currentTimeMillis() < deadline) Thread.sleep(100)
            // Seen twice in CI and not explained by the start and stop paths: name the service's state when it fails again.
            if (manager.activeNotifications.any { it.id == 1 }) {
                val services = shell("dumpsys activity services ${ui.activity.packageName}")
                fail("Disconnect left the VPN service in the foreground: connection=${repo.state.value.connection} " +
                    "error=${repo.state.value.error} refresh=${refresh.get()}\n$services")
            }
            assertEquals("disconnected", repo.state.value.connection)
        }
    }
    @Test fun e_resourceDestinationReview() {
        HTTPFixture().use { feed -> HTTPFixture().use { other ->
            feed.body = "example.test\nsub.example.test\n"
            other.body = "other.test\n"
            val profile = obj("Name" to "Managed fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "ManagedSources" to JSONArray(listOf(obj("id" to "fixture-domains", "url" to feed.url, "destination" to "block", "matchMode" to "subdomains"),
                    obj("id" to "other-domains", "url" to other.url, "destination" to "direct", "matchMode" to "exact"))))
            call("saveRouting", obj("text" to profile.toString()))
            val id = snapshot().routes.single().getString("id")
            val warning = call("refreshManaged", obj("id" to id)).getJSONObject("warning")
            assertTrue(snapshot().route(id).mapObject("lists").length() == 0)
            var result = call("approveResource", obj("token" to warning.getString("token")))
            while (result.has("warning")) result = call("approveResource", obj("token" to result.getJSONObject("warning").getString("token")))
            assertEquals(2, snapshot().route(id).mapObject("lists").getJSONArray("fixture-domains").length())
            assertEquals(listOf("full:other.test"), snapshot().route(id).mapObject("lists").strings("other-domains"))
            val scheduled = snapshot().route(id).getDouble("nextManagedRefreshAt")
            feed.body = "fresh.test\n"; other.body = "invalid domain with spaces"
            val otherRequests = other.requests.get()
            call("refreshManaged", obj("id" to id, "sourceId" to "fixture-domains"))
            assertEquals(listOf("domain:fresh.test"), snapshot().route(id).mapObject("lists").strings("fixture-domains"))
            assertEquals(listOf("full:other.test"), snapshot().route(id).mapObject("lists").strings("other-domains"))
            assertEquals(otherRequests, other.requests.get())
            assertEquals(scheduled, snapshot().route(id).getDouble("nextManagedRefreshAt"), 0.0)
            expectFailure { call("refreshManaged", obj("id" to id, "sourceId" to "unknown")) }
            feed.body = "invalid managed domain with spaces"
            assertEquals("invalid_input", expectFailure { call("refreshManaged", obj("id" to id, "sourceId" to "fixture-domains")) })
            // A full refresh updates each list on its own; a failed one keeps its last download.
            other.body = "another.test\n"
            call("refreshManaged", obj("id" to id))
            fun route() = snapshot().route(id)
            assertEquals(listOf("domain:fresh.test"), route().mapObject("lists").strings("fixture-domains"))
            assertEquals(listOf("full:another.test"), route().mapObject("lists").strings("other-domains"))
            assertEquals("invalid_input", route().string("managedError"))
            // Failures retry after 60, then 300 s, as subscriptions do; a success resets the schedule.
            assertEquals(now() + 60, route().getDouble("nextManagedRefreshAt"), 10.0)
            call("refreshManaged", obj("id" to id))
            assertEquals(now() + 300, route().getDouble("nextManagedRefreshAt"), 10.0)
            feed.body = "restored.test\n"
            call("refreshManaged", obj("id" to id))
            assertEquals(listOf("domain:restored.test"), route().mapObject("lists").strings("fixture-domains"))
            assertTrue(route().isNull("managedError"))
            assertEquals(now() + 86400, route().getDouble("nextManagedRefreshAt"), 10.0)
        } }
    }
    @Test fun f_leaveEncryptedCatalogForProcessRestart() {
        call("import", obj("text" to link("Restart fixture")))
        val id = snapshot().nodes.single().getString("id")
        call("select", obj("id" to id))
        call("favorite", obj("id" to id, "value" to true))
    }
    @Test fun e_geodataRefreshRetainsLastGoodAssets() {
        HTTPFixture().use { feed ->
            feed.binary = site("TEST", "example.test") + site("OTHER", "unused.test")
            val profile = obj("Name" to "Geodata fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "Geositeurl" to feed.url, "UseChunkFiles" to "true", "BlockSites" to JSONArray(listOf("geosite:test")))
            call("saveRouting", obj("text" to profile.toString()))
            val id = snapshot().routes.single().getString("id")
            val warning = call("refreshGeofiles", obj("id" to id)).getJSONObject("warning")
            call("approveResource", obj("token" to warning.getString("token")))
            val revision = snapshot().route(id).getString("assetRevision")
            val directory = File(RoutingAssets(ui.activity).directory(revision))
            val reduced = directory.resolve("geosite.dat").readBytes()
            assertTrue(reduced.size < feed.binary!!.size)
            val count = JSONObject(directory.resolve("geosite.json").readText())
            assertEquals(1, count.getInt("categoryCount")); assertEquals(1, count.getInt("ruleCount"))
            assertEquals("TEST", count.getJSONArray("codes").getJSONObject(0).getString("code"))
            call("refreshGeofiles", obj("id" to id))
            assertEquals(revision, snapshot().route(id).getString("assetRevision"))
            feed.binary = "broken geodata".toByteArray()
            assertEquals("invalid_geodata", expectFailure { call("refreshGeofiles", obj("id" to id)) })
            assertEquals(revision, snapshot().route(id).getString("assetRevision"))
            assertArrayEquals(reduced, directory.resolve("geosite.dat").readBytes())
            assertEquals(1, directory.parentFile!!.listFiles()!!.count { it.isDirectory })
            // Scheduled failures retry after 60, then 300 s, as subscriptions do; a success resets the schedule.
            fun route() = snapshot().route(id)
            fun maintain() { val requests = feed.requests.get(); ui.waitUntil(10_000) { runBlocking { repo.maintenance(route().getDouble("nextGeoRefreshAt")) }; feed.requests.get() > requests } }
            maintain()
            assertEquals("invalid_geodata", route().string("geofileError"))
            assertEquals(now() + 60, route().getDouble("nextGeoRefreshAt"), 10.0)
            maintain()
            assertEquals(now() + 300, route().getDouble("nextGeoRefreshAt"), 10.0)
            feed.binary = site("TEST", "example.test") + site("OTHER", "unused.test")
            maintain()
            assertTrue(route().isNull("geofileError"))
            // Geofiles refresh weekly, as on desktop and macOS.
            assertEquals(now() + 7 * 86400, route().getDouble("nextGeoRefreshAt"), 10.0)
            // A Block rule skips a code the geofile lacks, as an empty category; a Proxy rule needs it.
            call("saveRouting", obj("id" to id, "text" to profile.put("BlockSites", JSONArray(listOf("geosite:test", "geosite:missing"))).toString()))
            call("refreshGeofiles", obj("id" to id))
            assertEquals("[\"geosite:missing\"]", route().getJSONArray("skippedGeodata").toString())
            val skipped = JSONObject(File(RoutingAssets(ui.activity).directory(route().getString("assetRevision"))).resolve("geosite.json").readText())
            assertEquals(2, skipped.getInt("categoryCount")); assertEquals(1, skipped.getInt("ruleCount"))
            call("saveRouting", obj("id" to id, "text" to profile.put("ProxySites", JSONArray(listOf("geosite:missing"))).toString()))
            assertEquals("missing_geodata:geosite:missing", expectFailure { call("refreshGeofiles", obj("id" to id)) })
        }
    }
    @Test fun e_brokenProviderRoutingKeepsTheAppliedCatalog() {
        HTTPFixture().use { feed ->
            feed.body = link("Provider one")
            val id = subscribe(feed)
            // The refresh fails after writing the new servers into its candidate; none of that may apply.
            feed.body = link("Provider one", 18081); feed.headers = mapOf("routing" to "happ://routing/add/not-a-routing-profile")
            expectFailure { call("refresh", obj("id" to id)) }
            assertEquals(18080, endpointPort(snapshot()))
            assertEquals("failed", snapshot().source(id).string("status"))
        }
    }
    @Test fun e_providerRoutingKeepsTheUsersAssignment() {
        HTTPFixture().use { feed ->
            fun profile(name: String) = obj("Name" to name, "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8")
            fun routing(name: String) = "happ://routing/onadd/" + Base64.encodeToString(profile(name).toString().toByteArray(), Base64.NO_WRAP)
            feed.body = link("Provider one"); feed.headers = mapOf("routing" to routing("Provider routing"))
            val id = subscribe(feed)
            // Adding the subscription applies the provider's profile.
            val provider = snapshot().routes.single().getString("id")
            assertEquals(provider, snapshot().assignments.string(id))
            call("saveRouting", obj("text" to profile("My routing").toString()))
            val mine = snapshot().routes.single { it.string("name") == "My routing" }.getString("id")
            call("assignRouting", obj("id" to id, "routeId" to mine))
            feed.headers = mapOf("routing" to routing("Updated provider routing"))
            call("refresh", obj("id" to id))
            assertEquals(mine, snapshot().assignments.string(id))
            assertEquals("Updated provider routing", snapshot().route(provider).string("name"))
            // No profile is a choice too.
            call("assignRouting", obj("id" to id, "routeId" to ""))
            call("refresh", obj("id" to id))
            assertFalse(snapshot().assignments.has(id))
            // A restored backup keeps the choice.
            call("assignRouting", obj("id" to id, "routeId" to mine))
            val backup = call("backup", obj("password" to "synthetic backup password")).getString("text")
            call("restore", obj("text" to backup, "password" to "synthetic backup password"))
            val restored = snapshot().sources.single().getString("id")
            call("approveSource", obj("token" to call("refresh", obj("id" to restored)).getJSONObject("warning").getString("token")))
            val after = snapshot()
            assertEquals("My routing", after.route(after.assignments.string(restored)).string("name"))
        }
    }
    @Test fun e_newRoutingProfileKeepsTheOneThatHasItsName() {
        // "New profile" opens every draft as "My routing", with the name field on another tab.
        fun profile(blocked: String) = obj("Name" to "My routing", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
            "BlockSites" to JSONArray(listOf(blocked)))
        call("saveRouting", obj("id" to "", "text" to profile("first.example").toString()))
        call("saveRouting", obj("id" to "", "text" to profile("second.example").toString()))
        val routes = snapshot().routes.sortedBy { it.string("name") }
        assertEquals(listOf("My routing", "My routing 2"), routes.map { it.string("name") })
        assertEquals(listOf("first.example"), routes[0].getJSONObject("profile").strings("BlockSites"))
        assertEquals(listOf("second.example"), routes[1].getJSONObject("profile").strings("BlockSites"))
        assertEquals("My routing 2", routes[1].getJSONObject("profile").getString("Name"))
        // An edit keeps its profile, and a copy still takes a free name.
        call("saveRouting", obj("id" to routes[0].getString("id"), "text" to profile("third.example").toString()))
        call("duplicateRouting", obj("id" to routes[0].getString("id")))
        val after = snapshot().routes
        assertEquals(setOf("My routing", "My routing 2", "My routing copy"), after.map { it.string("name") }.toSet())
        assertEquals(listOf("third.example"), after.single { it.string("id") == routes[0].getString("id") }.getJSONObject("profile").strings("BlockSites"))
    }
    @Test fun e_base64ProviderTitleDecodesInTheURLSafeAlphabet() {
        HTTPFixture().use { feed ->
            // Unpadded base64url, which Happ-style panels also send.
            val title = "Провайдер ✓?>!"
            feed.body = link("Provider one")
            feed.headers = mapOf("profile-title" to "base64:" + Base64.encodeToString(title.toByteArray(), Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP))
            val id = subscribe(feed)
            assertEquals(title, snapshot().source(id).string("name"))
        }
    }
    @Test fun e_routingAddressedToElarniWinsOverOtherClients() {
        HTTPFixture().use { feed ->
            fun routing(scheme: String, name: String) = "$scheme://routing/onadd/" + Base64.encodeToString(obj("Name" to name, "RemoteDNSType" to "DoU",
                "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8").toString().toByteArray(), Base64.NO_WRAP)
            fun applied(id: String) = snapshot().let { it.route(it.assignments.string(id)).string("name") }
            // 3x-ui sends its Happ routing header to every client (3x-ui #5999).
            feed.body = link("Provider one") + "\n" + routing("happ", "Happ"); feed.headers = mapOf("routing" to routing("elarni", "Elarni"))
            val id = subscribe(feed)
            assertEquals("Elarni", applied(id))
            feed.body = link("Provider one") + "\n" + routing("elarni", "Elarni body"); feed.headers = mapOf("routing" to routing("happ", "Happ"))
            call("refresh", obj("id" to id))
            assertEquals("Elarni body", applied(id))
            // With nothing addressed to Elarni, Happ's routing still applies.
            feed.body = link("Provider one")
            call("refresh", obj("id" to id))
            assertEquals("Happ", applied(id))
        }
    }
    @Test fun e_scheduledRefreshThatCannotApplyBacksOff() {
        HTTPFixture().use { feed ->
            feed.body = link("Provider one")
            val id = subscribe(feed)
            val due = snapshot().source(id).getDouble("nextRefreshAt")
            fun profile(name: String) = obj("Name" to name, "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8")
            repeat(256) { call("saveRouting", obj("text" to profile("Local $it").toString())) }
            // The refresh itself succeeds; the provider's own routing profile fails only when the catalog is applied.
            feed.headers = mapOf("routing" to "happ://routing/add/" + Base64.encodeToString(profile("Provider routing").toString().toByteArray(), Base64.NO_WRAP))
            runBlocking { repo.maintenance(due) }
            val source = snapshot().source(id)
            assertEquals("catalog_limit", source.string("refreshError"))
            assertEquals(now() + 60, source.getDouble("nextRefreshAt"), 10.0)
            assertEquals(256, snapshot().routes.size)
        }
    }
    @Test fun e_failedRefreshSaysWhoseFaultItIs() {
        HTTPFixture().use { feed ->
            feed.body = link("Provider one")
            val id = subscribe(feed)
            for ((status, code) in listOf(404 to "subscription_unavailable", 403 to "subscription_denied", 429 to "rate_limited", 503 to "provider_error")) {
                feed.status = status
                assertEquals("HTTP $status", code, expectFailure { call("refresh", obj("id" to id)) })
                assertEquals(code, snapshot().source(id).string("refreshError"))
            }
        }
    }
    // TSPU freezes an SNI for about 120 s after a burst of handshakes; unattended recovery waits past it, longer each time.
    @Test fun e_unattendedRecoveryWaitsPastTheSNIFreeze() {
        val policy = Automation(obj("attempts" to 6)).apply { intent = true; path("wifi", true, 0.0) }
        var time = 0.0
        for (wait in listOf(150.0, 300.0, 600.0, 600.0)) {
            policy.unattended(time); policy.unattended(time + wait - 1)
            assertTrue(policy.exhausted)
            policy.unattended(time + wait)
            assertFalse(policy.exhausted)
            time += wait; policy.exhausted = true
        }
        // A passing check starts the waits over.
        policy.healthy(time); policy.exhausted = true
        policy.unattended(time); policy.unattended(time + 150)
        assertFalse(policy.exhausted)
    }
    // DPI cuts UDP transports and unusual ports first; mobile whitelists pass only Russian entries.
    @Test fun e_recoveryTriesTCP443FirstAndRussianEntriesInWhitelistMode() {
        fun config(protocol: String, port: Int, network: String = "tcp", alpn: String = "h2") = obj("outbounds" to JSONArray(listOf(obj("protocol" to protocol,
            "settings" to obj("vnext" to JSONArray(listOf(obj("address" to "example.com", "port" to port)))),
            "streamSettings" to obj("network" to network, "tlsSettings" to obj("alpn" to JSONArray(listOf(alpn))))))))
        assertTrue(Automation.tcp443(config("vless", 443)))
        assertFalse(Automation.tcp443(config("vless", 8443)))
        assertFalse(Automation.tcp443(config("vless", 443, "kcp")))
        assertFalse(Automation.tcp443(config("vless", 443, alpn = "h3")))
        assertFalse(Automation.tcp443(config("hysteria", 443)))
        assertTrue(Automation.tcp443(obj("outbounds" to JSONArray(listOf(obj("protocol" to "trojan", "settings" to obj("servers" to JSONArray(listOf(obj("port" to 443))))))))))
        assertFalse(Automation.tcp443(JSONObject()))
        val policy = Automation(JSONObject())
        val order = listOf("a", "b", "c", "d", "e"); val tcp = setOf("c", "e"); val russian = setOf("d")
        assertEquals(listOf("c", "e", "a", "b", "d"), policy.recoveryOrder(order, "a", tcp, russian))
        assertEquals(order, policy.recoveryOrder(order, "c", tcp, russian))
        policy.observe("a", false, false); policy.observe("d", true, true)
        assertFalse("One foreign failure is no whitelist", policy.whitelist)
        policy.observe("b", false, false); policy.observe("d", true, true)
        assertTrue(policy.whitelist)
        assertEquals(listOf("d", "a", "b", "c", "e"), policy.recoveryOrder(order, "c", tcp, russian))
        assertEquals(listOf("d", "c", "e", "a", "b"), policy.recoveryOrder(order, "a", tcp, russian))
        policy.observe("c", true, false)
        assertFalse("A foreign pass ends whitelist mode", policy.whitelist)
    }
    // Backups may come from another subscription; choosing a server by hand makes it the primary and keeps them.
    @Test fun e_recoveryBackupsSpanSubscriptionsAndSurviveAManualChoice() {
        call("import", obj("text" to link("Span A")))
        call("import", obj("text" to "#hide-url: yes\n" + link("%F0%9F%87%B7%F0%9F%87%BA Span B", 18081)))
        val catalog = snapshot()
        assertEquals(2, catalog.sources.size)
        val a = catalog.nodes.single { it.string("name") == "Span A" }.string("id")
        val b = catalog.nodes.single { it.string("name").endsWith("Span B") }.string("id")
        val locations = ServerLocations(ui.activity)
        assertTrue(locations.russianEntry(catalog.node(b).string("name")))
        assertFalse(locations.russianEntry(catalog.node(a).string("name")))
        call("select", obj("id" to a))
        fun recovery(russian: List<String>) = obj("configuration" to Automation.defaults().put("enabled", true).put("policy", "orderedFallback")
            .put("subscriptionID", catalog.sourceFor(a).string("id")).put("nodeIDs", JSONArray(listOf(a, b))).put("russianEntryNodeIDs", JSONArray(russian))
            .put("targets", JSONArray(listOf(obj("id" to "span", "url" to "http://127.0.0.1:9/health", "expectedStatus" to 204, "expectedBody" to "")))))
        assertEquals("invalid_automation", expectFailure { call("automation", recovery(listOf("missing"))) })
        call("automation", recovery(listOf(b)))
        call("select", obj("id" to b))
        val saved = snapshot().data.mapObject("automation")
        assertTrue(saved.optBoolean("enabled"))
        assertEquals("orderedFallback", saved.string("policy"))
        assertEquals(catalog.sourceFor(b).string("id"), saved.string("subscriptionID"))
        assertEquals(listOf(b, a), saved.strings("nodeIDs"))
        assertEquals(listOf(b), saved.strings("russianEntryNodeIDs"))
    }
    // Happ's fallback-url: a provider's backup URL serves the subscription while its main URL fails.
    @Test fun e_providerFallbackURLServesWhileTheMainURLFails() {
        HTTPFixture().use { feed -> HTTPFixture().use { backup ->
            backup.body = link("Backup")
            feed.body = link("Provider one")
            feed.headers = mapOf("fallback-url" to backup.url + "?token=b")
            val id = subscribe(feed)
            feed.status = 503
            var result = call("refresh", obj("id" to id))
            while (result.has("warning")) result = call("approveSource", obj("token" to result.getJSONObject("warning").getString("token")))
            assertEquals(1, backup.requests.get())
            assertEquals(listOf("Backup"), snapshot().source(id).objects("nodes").map { it.string("name") })
        } }
    }
    // The provider's Profile-Update-Interval is each subscription's default; the user's refreshHours option wins.
    @Test fun e_refreshFollowsTheProviderIntervalUnlessTheUserSetsOne() {
        HTTPFixture().use { feed ->
            feed.body = link("Provider one")
            feed.headers = mapOf("Profile-Update-Interval" to "12")
            val id = subscribe(feed)
            fun hours(): Double {
                val catalog = snapshot(); val source = catalog.source(id)
                return ((catalog.nextRefresh(source) ?: 0.0) - source.getDouble("lastSuccessfulFetch")) / 3600
            }
            assertTrue("provider interval: ${hours()} h", hours() in 10.8..13.2)
            call("sourceOptions", obj("id" to id, "options" to obj("refreshHours" to "2"), "fallbackHosts" to JSONArray()))
            call("refresh", obj("id" to id))
            assertTrue("override: ${hours()} h", hours() in 1.8..2.2)
            for (bad in listOf("0", "169", "1.5", "soon"))
                assertEquals(bad, "invalid_settings", expectFailure { call("sourceOptions", obj("id" to id, "options" to obj("refreshHours" to bad), "fallbackHosts" to JSONArray())) })
            assertEquals("2", snapshot().source(id).mapObject("fetchOptions").string("refreshHours"))
            // Without an override or a usable provider value, the app setting applies.
            call("sourceOptions", obj("id" to id, "options" to JSONObject(), "fallbackHosts" to JSONArray()))
            feed.headers = mapOf("Profile-Update-Interval" to "soon")
            call("refresh", obj("id" to id))
            assertTrue("app setting: ${hours()} h", hours() in 3.6..4.4)
        }
    }
    @Test fun e_backupRefusesWhatRestoreRejects() {
        call("import", obj("text" to link()))
        // 600 characters are 1,200 bytes: the catalog keeps the name, a restore would not.
        call("renameNode", obj("id" to snapshot().nodes.single().getString("id"), "name" to "é".repeat(600)))
        assertEquals("backup_unsupported", expectFailure { call("backup", obj("password" to "synthetic password only")) })
    }
    @Test fun e_cancelledServerTestSaysCancelled() {
        // The server accepts and never answers, so the test runs until Cancel.
        ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { server ->
            val held = java.util.Collections.synchronizedList(mutableListOf<Socket>())
            Executors.newSingleThreadExecutor().submit { runCatching { while (true) held.add(server.accept()) } }
            call("import", obj("text" to "socks://127.0.0.1:${server.localPort}#Silent%20server"))
            val id = snapshot().nodes.single().getString("id")
            val test = Executors.newSingleThreadExecutor().submit<String> {
                // A numeric target needs no lookup; proxied or direct, the request reaches the silent server.
                // The core refuses a test without the response it expects, as the app's own settings give.
                try { repo.engine.probe(snapshot(), id, obj("protocol" to "proxy", "url" to "http://127.0.0.1:${server.localPort}/", "timeout" to 10, "expectedStatus" to 204, "expectedBody" to "")); "succeeded" }
                catch (error: AppFailure) { error.code }
            }
            ui.waitUntil(10_000) { held.isNotEmpty() || test.isDone }
            assertFalse("The server test ended before Cancel: ${if (test.isDone) test.get() else ""}", test.isDone)
            Native.cancelOperations()
            assertEquals("probe_cancelled", test.get(10, java.util.concurrent.TimeUnit.SECONDS))
            held.forEach { it.close() }
        }
    }
    @Test fun e_cancelDuringServerTestSetupEndsTheTest() {
        // The server accepts and never answers, so an uncancelled test runs its whole 15 s.
        ServerSocket(0, 64, InetAddress.getByName("127.0.0.1")).use { server ->
            val held = java.util.Collections.synchronizedList(mutableListOf<Socket>())
            Executors.newSingleThreadExecutor().submit { runCatching { while (true) held.add(server.accept()) } }
            // Each test copies the catalog before it starts; a large one widens the window a cancel must not miss.
            call("import", obj("text" to (0 until 1000).joinToString("\n") { "socks://127.0.0.1:${server.localPort}#Silent%20$it" }))
            val id = snapshot().nodes.first().getString("id")
            val pool = Executors.newSingleThreadExecutor()
            try {
                repeat(40) { round ->
                    val started = android.os.SystemClock.elapsedRealtime()
                    val test = pool.submit { runCatching { call("ping", obj("id" to id, "protocol" to "proxy", "url" to "http://127.0.0.1:${server.localPort}/",
                        "timeout" to 15, "expectedStatus" to 204, "expectedBody" to "")) } }
                    // Busy rises once the test holds its generation; spin, as waitUntil returns after the few-millisecond setup has passed.
                    val deadline = System.nanoTime() + 5_000_000_000L
                    while (!repo.state.value.busy) { assertTrue("Round $round: the test never started", System.nanoTime() < deadline); Thread.yield() }
                    val cancelAt = System.nanoTime() + round * 1_000_000L
                    while (System.nanoTime() < cancelAt) Thread.yield()
                    repo.cancel()
                    test.get(30, java.util.concurrent.TimeUnit.SECONDS)
                    val elapsed = android.os.SystemClock.elapsedRealtime() - started
                    assertTrue("Round $round: a test cancelled during its setup ran for $elapsed ms", elapsed < 5000)
                    ui.waitUntil(5000) { !repo.state.value.busy }
                }
            } finally { pool.shutdownNow(); held.forEach { it.close() } }
        }
    }
    @Test fun e_cancelStopsTheRemainingListDownloads() {
        HTTPFixture().use { slow -> HTTPFixture().use { other ->
            slow.body = "slow.test\n"; other.body = "other.test\n"
            val profile = obj("Name" to "Cancel fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "ManagedSources" to JSONArray(listOf(obj("id" to "slow-domains", "url" to slow.url, "destination" to "block", "matchMode" to "exact"),
                    obj("id" to "other-domains", "url" to other.url, "destination" to "direct", "matchMode" to "exact"))))
            call("saveRouting", obj("text" to profile.toString()))
            val id = snapshot().routes.single().getString("id")
            var result = call("refreshManaged", obj("id" to id))
            while (result.has("warning")) result = call("approveResource", obj("token" to result.getJSONObject("warning").getString("token")))
            slow.stall = 10_000
            val requests = slow.requests.get(); val otherRequests = other.requests.get()
            val refresh = Executors.newSingleThreadExecutor().submit<String> {
                try { call("refreshManaged", obj("id" to id)); "completed" } catch (error: AppFailure) { error.code }
            }
            ui.waitUntil(10_000) { slow.requests.get() > requests }
            repo.cancel()
            assertEquals("fetch_cancelled", refresh.get(15, java.util.concurrent.TimeUnit.SECONDS))
            assertEquals(otherRequests, other.requests.get())
        } }
    }
    @Test fun e_rotatedKeysKeepSameNamedServers() {
        HTTPFixture().use { feed ->
            fun servers(key: Int) = listOf("tcp", "ws").joinToString("\n") { "vless://00000000-0000-4000-8000-00000000000$key@127.0.0.1:18080?encryption=none&security=none&type=$it#Same%20name" }
            fun network(node: JSONObject) = node.getJSONObject("config").objects("outbounds").first().mapObject("streamSettings").string("network")
            feed.body = servers(1)
            val id = subscribe(feed)
            val ids = snapshot().nodes.map { it.getString("id") }.toSet()
            val ws = snapshot().nodes.single { network(it) == "ws" }.getString("id")
            call("favorite", obj("id" to ws, "value" to true))
            // Same name, rotated keys: protocol, transport and security still tell the servers apart.
            feed.body = servers(2)
            call("refresh", obj("id" to id))
            assertEquals(ids, snapshot().nodes.map { it.getString("id") }.toSet())
            assertEquals("ws", network(snapshot().node(ws)))
            assertTrue(snapshot().node(ws).getBoolean("favorite"))
        }
    }
    @Test fun e_renamedServerKeepsItsNameAcrossRefresh() {
        HTTPFixture().use { feed ->
            fun servers(key: Int) = listOf("tcp", "ws").joinToString("\n") { "vless://00000000-0000-4000-8000-00000000000$key@127.0.0.1:18080?encryption=none&security=none&type=$it#Same%20name" }
            feed.body = servers(1)
            val id = subscribe(feed)
            val ids = snapshot().nodes.map { it.getString("id") }.toSet()
            val renamed = snapshot().nodes.first().getString("id")
            call("renameNode", obj("id" to renamed, "name" to "Home"))
            // As on desktop; with rotated keys the provider's name must still match the server.
            for (key in listOf(1, 2)) {
                feed.body = servers(key)
                call("refresh", obj("id" to id))
                assertEquals(ids, snapshot().nodes.map { it.getString("id") }.toSet())
                assertEquals("Home", snapshot().node(renamed).getString("name"))
            }
        }
    }
    @Test fun e_restoreKeepsTheProviderNameOfARenamedServer() {
        call("import", obj("text" to link()))
        call("renameNode", obj("id" to snapshot().nodes.single().getString("id"), "name" to "Home"))
        val password = "synthetic password only"
        call("restore", obj("text" to call("backup", obj("password" to password)).getString("text"), "password" to password))
        // Refresh matches a renamed server on the provider's name; without it a restored rename is lost again.
        val node = snapshot().nodes.single()
        assertEquals(listOf("Home", "Synthetic Android server"), listOf(node.getString("name"), node.string("providerName")))
    }
    @Test fun e_hiddenProviderServerStaysHiddenAcrossRefreshAndRestore() {
        HTTPFixture().use { feed ->
            feed.body = listOf("First", "Second", "Third").mapIndexed { i, name -> link(name, 18081 + i) }.joinToString("\n")
            val id = subscribe(feed)
            fun named(name: String) = snapshot().nodes.single { it.string("name") == name }.getString("id")
            val second = named("Second"); val third = named("Third")
            call("renameNode", obj("id" to second, "name" to "Mine"))
            call("favorite", obj("id" to second, "value" to true))
            call("deleteNode", obj("id" to third))
            call("refresh", obj("id" to id))
            // A provider's server the user removed stays out; a refresh must not add it back.
            assertEquals(listOf("First", "Mine"), snapshot().nodes.map { it.string("name") })
            assertEquals(listOf(third to "Third"), snapshot().sources.single().objects("hiddenNodes").map { it.string("id") to it.string("name") })
            val password = "synthetic password only"
            call("restore", obj("text" to call("backup", obj("password" to password)).getString("text"), "password" to password))
            val restored = snapshot()
            val mine = restored.nodes.single { it.string("name") == "Mine" }
            assertEquals("Second", mine.string("providerName"))
            assertTrue(mine.getBoolean("favorite"))
            val hidden = restored.sources.single().objects("hiddenNodes").single()
            assertEquals("Third", hidden.string("name"))
            call("showNode", obj("id" to hidden.getString("id")))
            assertEquals(listOf("First", "Mine", "Third"), snapshot().nodes.map { it.string("name") })
            assertTrue(snapshot().sources.single().objects("hiddenNodes").isEmpty())
        }
        // A local group has no refresh to add a server back, so its servers are deleted.
        call("import", obj("text" to link("Local", 18090)))
        val local = snapshot().sources.single { !it.has("url") }
        call("deleteNode", obj("id" to local.objects("nodes").single().getString("id")))
        assertTrue(snapshot().sources.none { it.objects("hiddenNodes").isNotEmpty() })
    }
    @Test fun e_serversHideTogetherAndCheckExitReadsTheTrace() {
        HTTPFixture().use { trace ->
            trace.body = "fl=29f\nip=203.0.113.7\nloc=DE\n"
            // Real SOCKS servers, so the check crosses the core's trace contract. An import keeps one server per endpoint.
            val ports = List(3) { ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort } }
            Native.call("runXrayFromJson", obj("configJSON" to obj("log" to obj("loglevel" to "none"),
                "inbounds" to JSONArray(ports.map { obj("listen" to "127.0.0.1", "port" to it, "protocol" to "socks", "settings" to obj("auth" to "noauth")) }),
                "outbounds" to JSONArray(listOf(obj("protocol" to "freedom")))).toString()))
            try {
                call("import", obj("text" to listOf("A", "B", "C").zip(ports).joinToString("\n") { (name, port) -> "socks://127.0.0.1:$port#Batch%20$name" }))
                val nodes = snapshot().nodes.map { it.getString("id") }
                call("select", obj("id" to nodes[0]))
                val result = call("ping", obj("id" to nodes[1], "protocol" to "proxy", "url" to trace.url, "method" to "GET", "timeout" to 5,
                    "expectedStatus" to 200, "expectedBody" to "", "trace" to true)).objects("results").single()
                assertEquals(result.toString(), "success", result.string("status"))
                assertEquals(listOf("203.0.113.7", "DE"), result.mapObject("exit").let { listOf(it.string("ip"), it.string("country")) })
                // An exit check is kept apart from latency results, which follow the configured test.
                assertEquals("DE", repo.state.value.exits.getValue(nodes[1]).mapObject("exit").string("country"))
                assertFalse(repo.state.value.pings.containsKey(nodes[1]))
                // The selected server stays, so a batch that includes it removes none.
                val refused = try { call("deleteNodes", obj("ids" to JSONArray(listOf(nodes[1], nodes[0])))); "completed" } catch (error: AppFailure) { error.code }
                assertEquals("invalid_input", refused)
                assertEquals(nodes, snapshot().nodes.map { it.getString("id") })
                call("deleteNodes", obj("ids" to JSONArray(listOf(nodes[1], nodes[2]))))
                assertEquals(listOf(nodes[0]), snapshot().nodes.map { it.getString("id") })
                assertFalse(repo.state.value.exits.containsKey(nodes[1]))
            } finally { Native.call("stopXray") }
        }
    }
    @Test fun e_deviceIDIsTheOneSentAndResetsOnlyItsSubscription() {
        HTTPFixture().use { feed ->
            feed.body = link()
            val first = subscribe(feed)
            val other = "${feed.url}?second"
            call("approveSource", obj("token" to call("import", obj("text" to other)).getJSONObject("warning").getString("token")))
            val second = snapshot().sources.single { it.string("url") == other }.getString("id")
            fun shown(id: String) = call("deviceID", obj("id" to id)).getString("deviceId")
            // The ID shown is the X-HWID the provider got; one origin gets one ID.
            assertEquals(feed.hwids.getValue("/feed"), shown(first))
            assertEquals(shown(first), shown(second))
            call("resetDeviceID", obj("id" to first))
            assertNotEquals(feed.hwids.getValue("/feed"), shown(first))
            assertEquals(feed.hwids.getValue("/feed?second"), shown(second))
            call("refresh", obj("id" to first))
            call("refresh", obj("id" to second))
            assertEquals(shown(first), feed.hwids.getValue("/feed"))
            assertEquals(shown(second), feed.hwids.getValue("/feed?second"))
            assertNotEquals(shown(first), shown(second))
            HTTPFixture().use { raw ->
                // In another format a refresh fetches that format's link, here on another host; the ID shown follows it.
                raw.body = link("Raw server")
                feed.body = obj("info" to obj("subUrl" to raw.url), "tag" to "proxy", "protocol" to "vless", "settings" to obj("vnext" to JSONArray(listOf(obj("address" to "127.0.0.1", "port" to 18080,
                    "users" to JSONArray(listOf(obj("id" to "00000000-0000-4000-8000-000000000001", "encryption" to "none")))))))).toString()
                call("refresh", obj("id" to second))
                call("refresh", obj("id" to second, "format" to "raw")).optJSONObject("warning")?.let { call("approveSource", obj("token" to it.getString("token"))) }
                assertEquals("raw", snapshot().source(second).string("format"))
                assertEquals(raw.hwids.getValue("/feed"), shown(second))
            }
        }
        call("import", obj("text" to link("Local", 18090)))
        val local = snapshot().sources.single { !it.has("url") }.getString("id")
        assertEquals("invalid_input", expectFailure { call("deviceID", obj("id" to local)) })
        assertEquals("invalid_input", expectFailure { call("resetDeviceID", obj("id" to local)) })
    }
    @Test fun e_freshInstallRequiresALoginOnItsLocalListeners() {
        // Other local apps must not reach a fresh install's listeners without a login (v2rayNG #5457).
        val fresh = Catalog.empty()
        assertTrue(fresh.settings.getBoolean("inboundAuthEnabled"))
        val login = fresh.data.getJSONObject("inboundCredentials")
        assertTrue(listOf("username", "password").all { Regex("^[0-9a-f]{32}$").matches(login.getString(it)) })
        assertNotEquals(login.toString(), Catalog.empty().data.getJSONObject("inboundCredentials").toString())
        call("import", obj("text" to link()))
        val proxyMode = Catalog(snapshot().data.put("settings", fresh.settings.put("xrayTunEnabled", false)).put("inboundCredentials", login))
        val socks = proxyMode.compile(proxyMode.nodes.single().getString("id"), vpn = false).getJSONArray("inbounds").let { inbounds ->
            (0 until inbounds.length()).map(inbounds::getJSONObject).single { it.getString("protocol") == "socks" }
        }
        assertEquals("password", socks.getJSONObject("settings").getString("auth"))
    }
    @Test fun e_providerDNSThatAsksTheSystemResolverIsNoted() {
        HTTPFixture().use { feed ->
            feed.body = """[{"remarks":"DNS fixture","dns":{"servers":["localhost"]},"outbounds":[{"protocol":"vless","settings":{"address":"127.0.0.1","port":443,"id":"00000000-0000-4000-8000-000000000001","encryption":"none"}}]}]"""
            val id = subscribe(feed)
            val metadata = snapshot().sources.single { it.string("id") == id }.mapObject("metadata")
            assertTrue(metadata.string("dnsNotice").startsWith("The provider's DNS asks this device's resolver"))
        }
    }
    @Test fun e_requiringALoginWithoutASavedOneGeneratesIt() {
        // Installs from 0.3.6 and earlier may have no login saved; requiring one then generates it.
        val store = EncryptedStore(ui.activity)
        val original = store.load()!!
        val old = JSONObject(original.getJSONObject("committed").toString())
        old.remove("inboundCredentials")
        old.getJSONObject("settings").put("inboundAuthEnabled", false).put("allowLAN", false)
        store.save(obj("journalVersion" to 1, "committed" to old))
        val upgraded = Repository(ui.activity.application as ElarniApplication)
        try {
            val saved = runBlocking {
                upgraded.awaitReady()
                upgraded.execute("settings", obj("settings" to obj("inboundAuthEnabled" to true)))
                Catalog(upgraded.execute("read"))
            }
            assertTrue(saved.settings.getBoolean("inboundAuthEnabled"))
            val login = saved.data.getJSONObject("inboundCredentials")
            assertTrue(listOf("username", "password").all { Regex("^[0-9a-f]{32}$").matches(login.getString(it)) })
        } finally {
            upgraded.scope.cancel()
            store.save(original)
        }
    }
    @Test fun e_unresolvableServerIsAConnectionFailure() {
        call("import", obj("text" to "vless://00000000-0000-4000-8000-000000000001@nonexistent.invalid:443?encryption=none&security=none&type=tcp#Gone"))
        val id = snapshot().nodes.single().getString("id")
        // Resolution fails at connect; the import message sent users to re-add a link that was fine.
        assertEquals("connection_failed", expectFailure { repo.engine.prepare(snapshot(), id) })
    }
    @Test fun e_pickerActionSurvivesProcessDeath() {
        ui.activityRule.scenario.onActivity { it.interaction.fileAction = "restore"; it.interaction.camera = android.net.Uri.parse("content://com.elarni.debug.files/shared/camera-qr.jpg") }
        // A process death keeps the saved state but not the ViewModel; a picked backup then arrived as an import.
        ui.activityRule.scenario.onActivity { it.viewModelStore.clear() }
        ui.activityRule.scenario.recreate()
        ui.activityRule.scenario.onActivity {
            assertEquals("restore", it.interaction.fileAction)
            assertEquals("content://com.elarni.debug.files/shared/camera-qr.jpg", it.interaction.camera.toString())
        }
    }
    @Test fun e_shareSheetOffersOnlyServersWithLinks() {
        val key = "AQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQE="
        call("import", obj("text" to link() + "\nwireguard://$key@127.0.0.1:51820?publickey=${key.replace("=", "%3D")}&address=10.0.0.2%2F32#WG"))
        val catalog = snapshot()
        assertEquals(2, catalog.nodes.size)
        // The share code writes no WireGuard links; offering one failed the whole batch.
        val offered = catalog.nodes.filter(catalog::linkable)
        assertEquals(listOf("Synthetic Android server"), offered.map { it.getString("name") })
        assertTrue(call("shareLinks", obj("ids" to JSONArray(offered.map { it.getString("id") }))).getString("text").startsWith("vless://"))
    }
    @Test fun e_uninstalledAppInPerAppListStillCompiles() {
        call("import", obj("text" to link()))
        val id = snapshot().nodes.single().getString("id")
        call("select", obj("id" to id))
        val installed = call("apps").objects("apps").first()
        call("settings", obj("settings" to obj("perAppMode" to "bypass", "perAppProcesses" to JSONArray(listOf(installed.getString("package"), "com.elarni.uninstalled.fixture")))))
        // While connected every change compiles this, so an uninstalled app must not fail it.
        val rules = snapshot().compile(id, ui.activity).getJSONObject("routing").getJSONArray("rules").toString()
        assertTrue(rules.contains("\"${installed.getInt("uid")}\""))
    }
    @Test fun e_perAppTargetsCompileExportAndFollowTheirServerThroughARestore() {
        call("import", obj("text" to link()))
        call("import", obj("text" to link("Second Android server", 18081)))
        val (first, second) = snapshot().nodes.map { it.getString("id") }
        call("select", obj("id" to first))
        val apps = call("apps").objects("apps").distinctBy { it.getInt("uid") }.take(3)
        val (blocked, served, proxied) = apps.map { it.getString("package") }
        fun save(targets: JSONObject) = call("settings", obj("settings" to obj("perAppMode" to "bypass", "perAppProcesses" to JSONArray(listOf(blocked, served, proxied)), "perAppTargets" to targets)))
        // A target names a listed app, and a proxy runs on this device, without a login, on a port that is not Elarni's own.
        for (bad in listOf(obj("com.elarni.unlisted" to "block"), obj(blocked to "server"), obj(blocked to "node:"), obj(blocked to 7),
            obj(blocked to "proxy:socks5://10.0.2.2:1080"), obj(blocked to "proxy:socks5://127.0.0.1"), obj(blocked to "proxy:https://127.0.0.1:1080"),
            obj(blocked to "proxy:socks5://user:secret@127.0.0.1:1080"), obj(blocked to "proxy:socks5://127.0.0.1:${snapshot().settings.getInt("socksPort")}"))) {
            assertEquals("$bad", "invalid_per_app", expectFailure { save(bad) })
        }
        save(obj(blocked to "block", served to "node:$second", proxied to "proxy:socks5://127.0.0.1:1080"))
        fun outbound(catalog: Catalog, app: JSONObject): JSONObject {
            val config = catalog.compile(catalog.selected, ui.activity)
            val uid = app.getInt("uid").toString()
            val tag = config.getJSONObject("routing").objects("rules").first { uid in (it.optJSONArray("process")?.strings() ?: emptyList()) }.getString("outboundTag")
            return config.objects("outbounds").first { it.string("tag") == tag }
        }
        assertEquals("blackhole", outbound(snapshot(), apps[0]).getString("protocol"))
        assertTrue(outbound(snapshot(), apps[1]).let { it.getString("protocol") == "vless" && it.toString().contains("18081") })
        assertEquals(obj("address" to "127.0.0.1", "port" to 1080).toString(), outbound(snapshot(), apps[2]).getJSONObject("settings").getJSONArray("servers").getJSONObject(0).toString())
        // Server IDs belong to this device, so a profile carries every other target.
        val export = JSONObject(call("exportPerApp").getString("text"))
        assertEquals(2, export.getInt("version"))
        assertEquals(obj(blocked to "block", proxied to "proxy:socks5://127.0.0.1:1080").toString(), export.getJSONObject("targets").toString())
        save(JSONObject())
        call("importPerApp", obj("text" to export.toString()))
        assertEquals(setOf(blocked, proxied), snapshot().settings.getJSONObject("perAppTargets").keys().asSequence().toSet())
        assertEquals("invalid_per_app", expectFailure { call("importPerApp", obj("text" to export.copy().apply { getJSONObject("targets").put(served, "node:$second") }.toString())) })
        // A restore gives every server a new ID; the app's target follows its server.
        save(obj(served to "node:$second"))
        val backup = call("backup", obj("password" to "synthetic password only")).getString("text")
        call("restore", obj("text" to backup, "password" to "synthetic password only"))
        val restored = snapshot().settings.getJSONObject("perAppTargets").getString(served).removePrefix("node:")
        assertNotEquals(second, restored)
        assertEquals("Second Android server", snapshot().node(restored).getString("name"))
        assertTrue(outbound(snapshot(), apps[1]).toString().contains("18081"))
        // Without its server the app has nowhere to go, so connecting fails instead of sending it another way.
        call("deleteNode", obj("id" to restored))
        assertEquals("per_app_target_missing", expectFailure { snapshot().let { it.compile(it.selected, ui.activity) } })
    }
    @Test fun e_routingEditKeepsDownloadedGeofiles() {
        HTTPFixture().use { feed ->
            feed.binary = site("TEST", "example.test") + site("OTHER", "unused.test")
            call("import", obj("text" to link()))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            call("settings", obj("settings" to obj("xrayTunEnabled" to false)))
            val profile = obj("Name" to "Geodata fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "Geositeurl" to feed.url, "UseChunkFiles" to "true", "BlockSites" to JSONArray(listOf("geosite:test")))
            call("saveRouting", obj("text" to profile.toString()))
            val id = snapshot().routes.single().getString("id")
            call("assignRouting", obj("id" to snapshot().sources.single().getString("id"), "routeId" to id))
            call("approveResource", obj("token" to call("refreshGeofiles", obj("id" to id)).getJSONObject("warning").getString("token")))
            val requests = feed.requests.get()
            // The edit names a code the reduced file lacks; Connect reduces the earlier download again.
            call("saveRouting", obj("id" to id, "text" to profile.put("BlockSites", JSONArray(listOf("geosite:test", "geosite:other"))).toString()))
            runBlocking { repo.requestConnect() }
            ui.waitUntil(15_000) { repo.state.value.connection in listOf("connected", "failed") }
            assertEquals("Connection error: ${repo.state.value.error}", "connected", repo.state.value.connection)
            assertEquals(requests, feed.requests.get())
            val counts = JSONObject(File(RoutingAssets(ui.activity).directory(snapshot().route(id).getString("assetRevision"))).resolve("geosite.json").readText())
            assertEquals(2, counts.getInt("ruleCount"))
        }
    }
    @Test fun e_dismissedExpiryReminderStaysDismissed() {
        val manager = allowNotifications()
        call("settings", obj("settings" to obj("expiryReminders" to true)))
        HTTPFixture().use { feed ->
            feed.body = link("Provider one"); feed.headers = mapOf("subscription-userinfo" to "expire=${(now() + 86400).toLong()}")
            subscribe(feed)
            runBlocking { repo.maintenance() }
            ui.waitUntil(5000) { manager.activeNotifications.any { it.id == 4 } }
            manager.cancel(4)
            // Maintenance runs every 30 s; the same expiring set reminds once a day.
            runBlocking { repo.maintenance() }
            Thread.sleep(1000)
            assertTrue(manager.activeNotifications.none { it.id == 4 })
        }
    }
    @Test fun e_refreshJobWaitsForTheCatalog() {
        val manager = allowNotifications()
        call("settings", obj("settings" to obj("expiryReminders" to true)))
        val job = "${ui.activity.packageName} ${ElarniApplication.REFRESH_JOB}"
        ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { silent ->
            val held = java.util.Collections.synchronizedList(mutableListOf<Socket>())
            Executors.newSingleThreadExecutor().submit { runCatching { while (true) held.add(silent.accept()) } }
            HTTPFixture().use { feed ->
                feed.body = "socks://127.0.0.1:${silent.localPort}#Silent%20server"
                feed.headers = mapOf("subscription-userinfo" to "expire=${(now() + 86400).toLong()}")
                subscribe(feed)
                // A run the change started must end first; only the forced run below may remind.
                ui.waitUntil(10_000) { !shell("cmd jobscheduler get-job-state $job").contains("active") }
                // The first subscription schedules the job, which then runs at once; its reminder would hold the
                // forced run's back for the day.
                manager.cancel(4)
                ui.activity.getSharedPreferences("reminders", android.content.Context.MODE_PRIVATE).edit().remove("expiry").commit()
                // Testing a server that never answers holds the catalog, as start-up does when the job starts the app.
                // Unlike a change, a test schedules nothing that could run the job again afterwards.
                val id = snapshot().nodes.single().getString("id")
                val test = Executors.newSingleThreadExecutor().submit<JSONObject> {
                    call("ping", obj("id" to id, "protocol" to "proxy", "url" to "http://127.0.0.1:${silent.localPort}/", "timeout" to 3, "expectedStatus" to 204, "expectedBody" to ""))
                }
                ui.waitUntil(10_000) { held.isNotEmpty() }
                shell("cmd jobscheduler run -f $job")
                test.get(15, java.util.concurrent.TimeUnit.SECONDS)
                // The job's pass waits for the test, then reminds of the expiring subscription.
                ui.waitUntil(10_000) { manager.activeNotifications.any { it.id == 4 } }
                // A subscription to refresh keeps an hourly job across reboots; with nothing left to refresh there is none.
                val scheduler = ui.activity.getSystemService(android.app.job.JobScheduler::class.java)
                val pending = scheduler.getPendingJob(ElarniApplication.REFRESH_JOB)!!
                assertTrue(pending.isPersisted && pending.isPeriodic)
                assertEquals(60 * 60 * 1000L, pending.intervalMillis)
                call("deleteSource", obj("id" to snapshot().sources.single().getString("id")))
                assertNull(scheduler.getPendingJob(ElarniApplication.REFRESH_JOB))
            }
            held.forEach { it.close() }
        }
    }
    @Test fun e_errorOutsideAnActionIsReportedNotFatal() {
        // An error that escapes background work must not end the process, and with it the VPN.
        repo.scope.launch { throw AppFailure("synthetic_failure") }
        ui.waitUntil(5000) { repo.state.value.error == "synthetic_failure" }
        assertEquals("synthetic_failure", repo.state.value.issues.first().string("code"))
    }
    @Test fun e_largeRoutingListSavesWithManyJsonServers() {
        val sites = (0 until 15000).map { "full:${"x".repeat(48)}-$it.example" }
        fun route(direct: List<String>) = obj("Name" to "Large route", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8", "DirectSites" to JSONArray(direct))
        call("import", obj("text" to JSONArray((0 until 40).map {
            obj("remarks" to "JSON $it", "outbounds" to JSONArray(listOf(obj("protocol" to "vless", "settings" to obj("address" to "127.0.0.1", "port" to 1000 + it, "id" to "00000000-0000-4000-8000-000000000001", "encryption" to "none")))))
        }).toString()))
        call("saveRouting", obj("text" to route(sites).toString()))
        val id = snapshot().routes.single().getString("id")
        call("assignRouting", obj("id" to snapshot().sources.single().getString("id"), "routeId" to id))
        // Every JSON server compiles the 15,000-domain list when the edit is validated.
        call("saveRouting", obj("id" to id, "text" to route(sites.drop(1) + "full:added.example").toString()))
        assertTrue("full:added.example" in snapshot().route(id).getJSONObject("profile").strings("DirectSites"))
    }
    @Test fun e_catalogOverItsLimitsSaysSo() {
        for ((key, count) in listOf("subscriptions" to 1025, "profiles" to 257)) {
            val catalog = Catalog.empty().apply { data.put(key, JSONArray((0 until count).map { obj("id" to "$it") })) }
            assertEquals(key, "catalog_limit", expectFailure { catalog.validate() })
        }
    }
    @Test fun e_changesAtTheServerLimit() {
        // A feed holds at most 1,024 profiles; four reach the catalog's 4,096-server limit.
        fun servers(feed: Int, skip: Int = -1, moved: Int = -1) = (0 until 1024).filter { it != skip }
            .joinToString("\n") { link("Server $feed-$it", if (it == moved) 9000 else 10000 + feed * 1024 + it) }
        val feeds = List(4) { HTTPFixture() }
        try {
            val ids = feeds.mapIndexed { index, feed -> feed.body = servers(index); subscribe(feed) }
            assertEquals(4096, snapshot().nodes.size)
            call("select", obj("id" to snapshot().source(ids[0]).objects("nodes").first().getString("id")))
            // Applying a change compiles every server to validate it; all of them at once ran out of memory on API 30.
            feeds[3].body = servers(3, skip = 0, moved = 1) + "\n" + link("Server 3-new", 9001)
            call("refresh", obj("id" to ids[3]))
            assertEquals(4096, snapshot().nodes.size)
            assertTrue(snapshot().nodes.any { it.string("name") == "Server 3-new" })
            // Editing a routing profile that every feed uses changes every server's compiled routing.
            val profile = obj("Name" to "Limit routing", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "DirectSites" to JSONArray(listOf("domain:one.test")))
            call("saveRouting", obj("text" to profile.toString()))
            val route = snapshot().routes.single().getString("id")
            ids.forEach { call("assignRouting", obj("id" to it, "routeId" to route)) }
            call("saveRouting", obj("id" to route, "text" to profile.put("DirectSites", JSONArray(listOf("domain:one.test", "domain:two.test"))).toString()))
            assertEquals(listOf("domain:one.test", "domain:two.test"), snapshot().route(route).getJSONObject("profile").strings("DirectSites"))
        } finally { feeds.forEach { it.close() } }
    }
    @Test fun e_extSiteRuleKeepsTheWholeGeofile() {
        HTTPFixture().use { feed ->
            feed.binary = site("TEST", "example.test") + site("OTHER", "other.test")
            // Xray reads ext-site: from the named file as it does ext:, so reduction must keep the file whole.
            val profile = obj("Name" to "External fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "Geositeurl" to feed.url, "UseChunkFiles" to "true", "ProxySites" to JSONArray(listOf("geosite:test", "ext-site:geosite.dat:other")))
            call("saveRouting", obj("text" to profile.toString()))
            val id = snapshot().routes.single().getString("id")
            refreshGeofiles(id)
            assertEquals("fullFileFallback", snapshot().route(id).string("reductionStatus"))
            assertArrayEquals(feed.binary, File(RoutingAssets(ui.activity).directory(snapshot().route(id).getString("assetRevision"))).resolve("geosite.dat").readBytes())
        }
    }
    @Test fun e_shortBackupPasswordSaysSo() {
        call("import", obj("text" to link()))
        assertEquals("invalid_backup_password", expectFailure { call("backup", obj("password" to "too short")) })
    }
    // TSPU freezes an SNI after more than 3 handshakes under ~50 ms apart.
    @Test fun e_bulkTestsRunTwoProbesPerSNIAtOnce() {
        ServerSocket(0, 50, InetAddress.getByName("127.0.0.1")).use { server ->
            val arrivals = java.util.Collections.synchronizedList(mutableListOf<Long>())
            val pool = Executors.newCachedThreadPool()
            // The server never answers the ClientHello, so each probe dials once and waits out its timeout.
            pool.submit { while (!server.isClosed) { val socket = runCatching { server.accept() }.getOrNull() ?: break
                arrivals.add(System.nanoTime() / 1_000_000)
                pool.submit { socket.use { it.soTimeout = 10_000; runCatching { while (it.getInputStream().read(ByteArray(4096)) >= 0) { } } } } } }
            try {
                HTTPFixture().use { feed ->
                    feed.body = (1..6).joinToString("\n") { "vless://00000000-0000-4000-8000-00000000000$it@127.0.0.1:${server.localPort}?encryption=none&security=tls&sni=shared.example&type=tcp#Shared%20$it" }
                    val id = subscribe(feed)
                    call("ping", obj("sourceId" to id, "protocol" to "proxy", "url" to "http://127.0.0.1:9/", "timeout" to 3, "expectedStatus" to 204, "expectedBody" to ""))
                }
            } finally { pool.shutdownNow() }
            val times = synchronized(arrivals) { arrivals.sorted() }
            assertTrue("arrivals $times", times.size >= 6 && times.indices.drop(2).all { times[it] - times[it - 2] >= 50 })
        }
    }
    @Test fun e_testingEveryServerOfAFullCatalog() {
        // Four feeds of 1,024 servers reach the 4,096-server limit; every test worker copied all of them.
        val feeds = List(4) { HTTPFixture() }
        try {
            val ids = feeds.mapIndexed { index, feed -> feed.body = (0 until 1024).joinToString("\n") { link("Server $index-$it", 10000 + index * 1024 + it) }; subscribe(feed) }
            val results = call("ping", obj("sourceId" to ids[0], "protocol" to "proxy", "url" to "http://127.0.0.1:9/", "timeout" to 1, "expectedStatus" to 204, "expectedBody" to ""))
            assertEquals(1024, results.getJSONArray("results").length())
        } finally { feeds.forEach { it.close() } }
    }
    @Test fun e_geofileRefreshDownloadsOnlyAChangedFile() {
        HTTPFixture().use { feed ->
            feed.binary = site("TEST", "example.test"); feed.etag = "\"v1\""
            val id = geodataRoute("Conditional geofile", feed).also(::refreshGeofiles)
            val revision = snapshot().route(id).getString("assetRevision")
            refreshGeofiles(id)
            assertEquals("the stored ETag was not sent", 1, feed.notModified.get())
            assertEquals(revision, snapshot().route(id).getString("assetRevision"))
            feed.binary = site("TEST", "changed.test"); feed.etag = "\"v2\""
            refreshGeofiles(id)
            assertNotEquals(revision, snapshot().route(id).getString("assetRevision"))
            refreshGeofiles(id)
            assertEquals("the new ETag was not stored", 2, feed.notModified.get())
        }
    }
    @Test fun e_geofileOverTheCoreLimitIsReducedOrRefused() {
        HTTPFixture().use { feed ->
            // A runetfreedom geosite.dat is 85 MB, most of it categories few profiles name; the app streams it to disk.
            feed.binary = largeSite("TEST", "example.test", 70 * 1024 * 1024)
            val reduced = geodataRoute("Reduced large geofile", feed, chunked = true).also(::refreshGeofiles)
            val route = snapshot().route(reduced)
            val file = route.getJSONArray("geofiles").getJSONObject(0)
            assertEquals("ready", route.getString("geofileStatus"))
            assertTrue(file.toString(), file.getLong("originalBytes") > 70L * 1024 * 1024 && file.getLong("bytes") < 1024)
            // The core would load a complete file whole.
            val complete = geodataRoute("Complete large geofile", feed)
            val code = try { refreshGeofiles(complete); "ready" } catch (error: AppFailure) { error.code }
            assertEquals("input_too_large", code)
        }
    }
    @Test fun e_routeFailureAfterAnotherRouteAppliesIsRecorded() {
        HTTPFixture().use { one -> HTTPFixture().use { two ->
            one.binary = site("TEST", "one.test"); two.binary = site("TEST", "two.test")
            geodataRoute("Route one", one).let(::refreshGeofiles)
            val failing = geodataRoute("Route two", two).also(::refreshGeofiles)
            two.binary = "broken geodata".toByteArray()
            // The first route's refresh applies and replaces the catalog; the second one's failure must still count.
            runBlocking { repo.maintenance(snapshot().routes.maxOf { it.getDouble("nextGeoRefreshAt") } + 1) }
            assertEquals("invalid_geodata", snapshot().route(failing).string("geofileError"))
            assertEquals(now() + 60, snapshot().route(failing).getDouble("nextGeoRefreshAt"), 10.0)
        } }
    }
    @Test fun e_routeReviewIsNotDroppedByALaterRoute() {
        HTTPFixture().use { managed -> HTTPFixture().use { two ->
            managed.body = "example.test\n"; two.binary = site("TEST", "two.test")
            // A managed list is due at once and its first download needs approval; this route is refreshed first.
            call("saveRouting", obj("text" to obj("Name" to "Managed first", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "ManagedSources" to JSONArray(listOf(obj("id" to "fixture-domains", "url" to managed.url, "destination" to "block", "matchMode" to "subdomains")))).toString()))
            val second = geodataRoute("Route two", two).also(::refreshGeofiles)
            two.binary = site("TEST", "changed.test")
            val requests = two.requests.get()
            runBlocking { repo.maintenance(snapshot().route(second).getDouble("nextGeoRefreshAt") + 1) }
            // Refreshing on would stack a second review or apply a change, and applying either clears this one unseen.
            assertNotNull("the managed list review was dropped", repo.state.value.approval)
            assertEquals("another route refreshed while a review waited", requests, two.requests.get())
        } }
    }
    @Test fun e_negatedServerRuleKeepsItsCode() {
        HTTPFixture().use { feed ->
            feed.binary = ip("US", 198) + ip("OTHER", 203)
            call("saveRouting", obj("text" to obj("Name" to "Negated fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "Geoipurl" to feed.url, "UseChunkFiles" to "true", "ProxyIp" to JSONArray(listOf("geoip:us"))).toString()))
            val id = snapshot().routes.single().getString("id")
            refreshGeofiles(id)
            call("import", obj("text" to JSONArray(listOf(obj("remarks" to "Negated rule", "outbounds" to JSONArray(listOf(
                obj("tag" to "proxy", "protocol" to "vless", "settings" to obj("address" to "127.0.0.1", "port" to 18080, "id" to "00000000-0000-4000-8000-000000000001", "encryption" to "none")),
                obj("tag" to "direct", "protocol" to "freedom"))),
                "routing" to obj("rules" to JSONArray(listOf(obj("type" to "field", "ip" to JSONArray(listOf("!geoip:ru")), "outboundTag" to "direct"))))))).toString()))
            // Xray reads a leading ! like one before the code and cannot start without that code.
            val code = expectFailure { call("assignRouting", obj("id" to snapshot().sources.single().getString("id"), "routeId" to id)); refreshGeofiles(id) }
            assertEquals("missing_geodata:geoip:ru", code)
        }
    }
    @Test fun e_localImportsJoinOneGroupAndSkipKnownServers() {
        call("import", obj("text" to link()))
        val first = snapshot().sources.single()
        call("renameSource", obj("id" to first.getString("id"), "name" to "My servers"))
        // A renamed copy is the same server; another port is not.
        call("import", obj("text" to link("Copy") + "\n" + link("Other", 18081)))
        val joined = snapshot().sources.single()
        assertEquals("My servers", joined.string("name"))
        assertEquals(listOf("Synthetic Android server", "Other"), joined.objects("nodes").map { it.string("name") })
        assertEquals(first.objects("nodes").single().getString("id"), joined.objects("nodes").first().getString("id"))
    }
    @Test fun e_overlongNameSaysWhichLimit() {
        assertEquals("catalog_limit", expectFailure { call("import", obj("text" to link("x".repeat(1025)))) })
        call("import", obj("text" to link("x".repeat(1024))))
    }
    @Test fun e_shareWithoutAFileIsIgnored() {
        val launchIntent = Intent(ui.activity.intent)
        // Any app may send this; an extra that is no Uri must not crash the app.
        ui.activity.runOnUiThread { ui.activity.startActivity(Intent(ui.activity, MainActivity::class.java).setAction(Intent.ACTION_SEND).setType("image/png").putExtra(Intent.EXTRA_STREAM, android.os.Bundle())) }
        ui.waitUntil(5000) { ui.activity.intent.action == Intent.ACTION_SEND }
        ui.waitForIdle()
        assertTrue(snapshot().nodes.isEmpty())
        ui.runOnUiThread { ui.activity.intent = launchIntent }
    }
    @Test fun e_shareOfAnUnknownParcelableIsIgnored() {
        // Another app's Parcelable class is unknown here; renaming this one inside the parcel makes reading the extras throw.
        val parcel = android.os.Parcel.obtain()
        android.os.Bundle().apply { putParcelable(Intent.EXTRA_STREAM, ForeignParcelable()) }.writeToParcel(parcel, 0)
        val bytes = parcel.marshall(); parcel.recycle()
        val name = ForeignParcelable::class.java.name.toByteArray(Charsets.UTF_16LE)
        val at = (0..bytes.size - name.size).first { bytes.copyOfRange(it, it + name.size).contentEquals(name) }
        bytes[at + name.size - 2] = '_'.code.toByte()
        val extras = android.os.Parcel.obtain().run { unmarshall(bytes, 0, bytes.size); setDataPosition(0); android.os.Bundle.CREATOR.createFromParcel(this).also { recycle() } }
        val launchIntent = Intent(ui.activity.intent)
        ui.activity.runOnUiThread { ui.activity.startActivity(Intent(ui.activity, MainActivity::class.java).setAction(Intent.ACTION_SEND).setType("text/plain").replaceExtras(extras)) }
        ui.waitUntil(5000) { ui.activity.intent.action == Intent.ACTION_SEND }
        ui.waitForIdle()
        assertTrue(snapshot().nodes.isEmpty())
        ui.runOnUiThread { ui.activity.intent = launchIntent }
    }
    @Test fun e_linkReplayedFromRecentsIsIgnored() {
        call("import", obj("text" to link()))
        call("select", obj("id" to snapshot().nodes.single().getString("id")))
        shell("appops set ${ui.activity.packageName} ACTIVATE_VPN allow"); allowNotifications()
        val launchIntent = Intent(ui.activity.intent)
        // Recents can reopen a task with the link that first opened it, which is no new request to connect.
        ui.activity.runOnUiThread { ui.activity.startActivity(Intent(Intent.ACTION_VIEW, android.net.Uri.parse("elarni://connect"), ui.activity, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY)) }
        try {
            ui.waitUntil(5000) { ui.activity.intent.dataString == "elarni://connect" }
            val deadline = android.os.SystemClock.elapsedRealtime() + 5000
            while (android.os.SystemClock.elapsedRealtime() < deadline) { assertEquals("disconnected", repo.state.value.connection); Thread.sleep(100) }
        } finally { ui.runOnUiThread { ui.activity.intent = launchIntent } }
    }
    @Test fun e_assignedRouteKeepsItsSkippedCodes() {
        HTTPFixture().use { feed ->
            feed.binary = ip("US", 198) + ip("OTHER", 203)
            call("saveRouting", obj("text" to obj("Name" to "Assigned fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "Geoipurl" to feed.url, "UseChunkFiles" to "true", "ProxyIp" to JSONArray(listOf("geoip:us")), "DirectIp" to JSONArray(listOf("geoip:ru"))).toString()))
            val id = snapshot().routes.single().getString("id")
            refreshGeofiles(id)
            call("import", obj("text" to JSONArray(listOf(obj("remarks" to "Assigned server", "outbounds" to JSONArray(listOf(
                obj("tag" to "proxy", "protocol" to "vless", "settings" to obj("address" to "127.0.0.1", "port" to 18080, "id" to "00000000-0000-4000-8000-000000000001", "encryption" to "none"))))))).toString()))
            // The route's Direct rule skips a code the geofile lacks for the servers it is assigned to as well.
            call("assignRouting", obj("id" to snapshot().sources.single().getString("id"), "routeId" to id))
            refreshGeofiles(id)
            assertEquals("[\"geoip:ru\"]", snapshot().route(id).getJSONArray("skippedGeodata").toString())
        }
    }
    @Test fun e_formatRefreshKeepsTheOtherFormats() {
        HTTPFixture().use { feed ->
            // Only the default format's response names the provider's other formats.
            feed.body = obj("info" to obj("subUrl" to "${feed.url}/raw"), "tag" to "proxy", "protocol" to "vless", "settings" to obj("vnext" to JSONArray(listOf(obj("address" to "127.0.0.1", "port" to 18080,
                "users" to JSONArray(listOf(obj("id" to "00000000-0000-4000-8000-000000000001", "encryption" to "none")))))))).toString()
            val id = subscribe(feed)
            assertEquals("${feed.url}/raw", snapshot().source(id).mapObject("links").string("raw"))
            fun refresh(format: String = "") = call("refresh", obj("id" to id, "format" to format)).optJSONObject("warning")?.let { call("approveSource", obj("token" to it.getString("token"))) }
            feed.body = link("Raw server")
            refresh("raw")
            refresh()
            assertEquals("raw", snapshot().source(id).string("format"))
            assertEquals("${feed.url}/raw", snapshot().source(id).mapObject("links").string("raw"))
        }
    }
    @Test fun e_sourceReviewLetsTheOthersRefresh() {
        HTTPFixture().use { one -> HTTPFixture().use { two -> HTTPFixture().use { moved ->
            one.body = link("Provider one"); two.body = link("Provider two", 18081); moved.body = link("Provider moved", 18082)
            val first = subscribe(one); val second = subscribe(two)
            assertEquals(listOf(first, second), snapshot().sources.map { it.getString("id") })
            // The first provider now redirects to a destination nobody approved; its review must not hold back the second.
            one.redirect = moved.url
            val time = snapshot().sources.maxOf { it.getDouble("nextRefreshAt") } + 1
            val requests = two.requests.get()
            runBlocking { repo.maintenance(time) }
            assertNotNull(repo.state.value.approval)
            call("reject")
            runBlocking { repo.maintenance(time) }
            assertTrue("the second provider never refreshed", two.requests.get() > requests)
        } } }
    }
    @Test fun e_cancelEndsTheBackgroundPass() {
        HTTPFixture().use { slow -> HTTPFixture().use { geo ->
            slow.body = "slow.test\n"; geo.binary = site("TEST", "example.test")
            call("saveRouting", obj("text" to obj("Name" to "Background cancel", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "Geositeurl" to geo.url, "BlockSites" to JSONArray(listOf("geosite:test")),
                "ManagedSources" to JSONArray(listOf(obj("id" to "slow-domains", "url" to slow.url, "destination" to "block", "matchMode" to "exact")))).toString()))
            val id = snapshot().routes.single().getString("id")
            var result = call("refreshManaged", obj("id" to id))
            while (result.has("warning")) result = call("approveResource", obj("token" to result.getJSONObject("warning").getString("token")))
            refreshGeofiles(id)
            fun route() = snapshot().route(id)
            slow.stall = 10_000
            val requests = slow.requests.get(); val geoRequests = geo.requests.get()
            val time = maxOf(route().getDouble("nextManagedRefreshAt"), route().getDouble("nextGeoRefreshAt")) + 1
            val pass = Executors.newSingleThreadExecutor().submit { runBlocking { repo.maintenance(time) } }
            ui.waitUntil(10_000) { slow.requests.get() > requests }
            repo.cancel()
            pass.get(15, java.util.concurrent.TimeUnit.SECONDS)
            // A cancelled download is no failure to retry later, and the pass ends with it.
            assertEquals(0, route().optInt("managedFailures"))
            assertEquals(geoRequests, geo.requests.get())
        } }
    }
    @Test fun e_serverLocationsMatchTheDesktop() {
        val locations = ServerLocations(ui.activity)
        // The desktop's cases in test/server_browser_test.dart.
        for ((name, code) in listOf("🇳🇱 Amsterdam" to "NL", "Netherlands 01" to "NL", "Нидерланды 02" to "NL", "NL-03" to "NL", "[NL] 04" to "NL", "United Kingdom 01" to "GB",
            "UK London" to "GB", "[UK] 02" to "GB", "UAE Dubai" to "AE", "UAE-01" to "AE", "ОАЭ 03" to "AE", "CF | 🇩🇪 Frankfurt" to "DE", "🇺🇸 New Jersey" to "US",
            "🇪🇺 Europe" to "EU", "EU-01" to "EU", "European Union 02" to "EU", "Евросоюз 03" to "EU", "🇪🇺 🇩🇪 Frankfurt" to "DE")) assertEquals(name, code, locations.fromName(name)?.code)
        for (name in listOf("Private server", "Amsterdam", "Fast online", "Connect IN seconds", "🇳🇱 → 🇩🇪", "Netherlands / Germany", "CF | Fast", "New Jersey 01", "Jersey City", "New Mexico"))
            assertNull(name, locations.fromName(name))
        assertEquals("United States", locations.fromName("🇺🇸 New York")?.name)
        assertEquals("Amsterdam 01", locations.displayName("🇳🇱 Amsterdam 01"))
        // Home draws every location's flag; scripts/export-android-flags exports them.
        JSONArray(ui.activity.assets.open("server-locations.json").bufferedReader().use { it.readText() }).objects().forEach { assertNotNull(it.string("code"), locations.flagImage(it.string("code"))) }
    }
    @Test fun e_hexOnlyHostnamesAreNamesNotAddresses() {
        // These resolve; taken as addresses they skipped the physical network's resolver and lost an address family.
        for (name in listOf("abc.de", "fab.de")) assertEquals(name, "invalid_settings", expectFailure { Settings.numericAddress(name) })
        assertEquals(InetAddress.getByAddress(byteArrayOf(192.toByte(), 0, 2, 1)), Settings.numericAddress("192.0.2.1"))
        assertTrue(Settings.numericAddress("2001:db8::1") is java.net.Inet6Address)
    }
    @Test fun e_restoreSkipsAGroupChoiceTheProviderDropped() {
        call("import", obj("text" to link()))
        val password = "synthetic password only"
        val catalog = Native.call("openCatalogBackup", obj("text" to call("backup", obj("password" to password)).getString("text"), "password" to password)).getJSONObject("catalog")
        // Refreshes keep a choice for a group the provider renamed or removed.
        catalog.objects("subscriptions").single().objects("nodes").single().put("groupOverrides", obj("Auto" to "DE"))
        call("restore", obj("text" to sealByHand(catalog, password), "password" to password))
        assertEquals(1, snapshot().nodes.size)
    }
    @Test fun e_trustedWiFiNamesKeepToWiFiLimits() {
        for (bad in listOf(listOf("x".repeat(33)), listOf("\u00e9".repeat(17)), listOf("tab\there"), listOf(""), (0..64).map { "n$it" }, listOf(42))) {
            assertEquals("$bad", "invalid_trusted_wifi", expectFailure { call("settings", obj("settings" to obj("trustedWiFiNetworks" to JSONArray(bad)))) })
        }
        assertEquals("invalid_trusted_wifi", expectFailure { call("settings", obj("settings" to obj("trustedWiFiNetworks" to "Home"))) })
        val names = listOf("x".repeat(32), "Caf\u00e9 5G") + (0 until 62).map { "n$it" }
        call("settings", obj("settings" to obj("connectOnUntrustedWiFi" to true, "trustedWiFiNetworks" to JSONArray(names))))
        assertEquals(names, snapshot().settings.strings("trustedWiFiNetworks"))
        assertTrue(snapshot().settings.getBoolean("connectOnUntrustedWiFi"))
        // The running core reads neither, so changing them keeps every connection.
        val runtime = Settings.runtime(snapshot().settings)
        assertFalse(runtime.has("trustedWiFiNetworks") || runtime.has("connectOnUntrustedWiFi"))
        call("settings", obj("settings" to obj("connectOnUntrustedWiFi" to false, "trustedWiFiNetworks" to JSONArray())))
    }

    @Test fun e_fallbackHostsKeepTheCoreLimit() {
        HTTPFixture().use { feed ->
            feed.body = link("Provider one")
            val id = subscribe(feed)
            fun hosts(count: Int) = JSONArray((1..count).map { "fallback$it.example" })
            // The core fetches with at most 8 fallback hosts; a 9th made every refresh and backup fail.
            assertEquals("invalid_target", expectFailure { call("sourceOptions", obj("id" to id, "options" to JSONObject(), "fallbackHosts" to hosts(9))) })
            call("sourceOptions", obj("id" to id, "options" to JSONObject(), "fallbackHosts" to hosts(8)))
            call("refresh", obj("id" to id))
        }
    }
    private fun geodataRoute(name: String, feed: HTTPFixture, chunked: Boolean = false): String {
        call("saveRouting", obj("text" to obj("Name" to name, "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
            "Geositeurl" to feed.url, "BlockSites" to JSONArray(listOf("geosite:test")), "UseChunkFiles" to chunked.toString()).toString()))
        return snapshot().routes.single { it.string("name") == name }.getString("id")
    }
    private fun refreshGeofiles(id: String) {
        var result = call("refreshGeofiles", obj("id" to id))
        while (result.has("warning")) result = call("approveResource", obj("token" to result.getJSONObject("warning").getString("token")))
    }
    private fun subscribe(feed: HTTPFixture): String {
        call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
        return snapshot().sources.single { it.string("url") == feed.url }.getString("id")
    }
    private fun allowNotifications(): android.app.NotificationManager {
        if (android.os.Build.VERSION.SDK_INT >= 33) InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(ui.activity.packageName, android.Manifest.permission.POST_NOTIFICATIONS)
        return ui.activity.getSystemService(android.app.NotificationManager::class.java)
    }
    private fun shell(command: String) = android.os.ParcelFileDescriptor.AutoCloseInputStream(InstrumentationRegistry.getInstrumentation().uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    // Sealing refuses a catalog that restore rejects; seal one by hand, as an altered backup would be.
    private fun sealByHand(catalog: JSONObject, password: String): String {
        val random = java.security.SecureRandom()
        val salt = ByteArray(16).also(random::nextBytes); val nonce = ByteArray(12).also(random::nextBytes)
        val key = javax.crypto.SecretKeyFactory.getInstance("PBKDF2WithHmacSHA256").generateSecret(javax.crypto.spec.PBEKeySpec(password.toCharArray(), salt, 600000, 256)).encoded
        val cipher = javax.crypto.Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(javax.crypto.Cipher.ENCRYPT_MODE, javax.crypto.spec.SecretKeySpec(key, "AES"), javax.crypto.spec.GCMParameterSpec(128, nonce))
            updateAAD("elarni.backup.v1".toByteArray())
        }
        fun encode(bytes: ByteArray) = Base64.encodeToString(bytes, Base64.NO_WRAP)
        return obj("format" to "elarni-backup", "version" to 1, "salt" to encode(salt), "nonce" to encode(nonce), "data" to encode(cipher.doFinal(catalog.toString().toByteArray()))).toString()
    }
    private fun endpointPort(catalog: Catalog) = Native.domain("profileEndpoints", obj("config" to catalog.compile(catalog.nodes.single().getString("id")))).objects("endpoints").first().getInt("port")
    private fun expectFailure(action: () -> Any?): String {
        try { action(); fail("Expected operation to fail") } catch (error: AppFailure) { return error.code }
        throw AssertionError("No failure")
    }
}

class AndroidRestartE2E {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()
    @Test fun committedCatalogSurvivesProcessRestart() {
        val repository = ui.activity.repository
        ui.waitUntil(10_000) { !repository.state.value.loading }
        val catalog = Catalog(runBlocking { repository.execute("read") })
        assertEquals("Restart fixture", catalog.node(catalog.selected).getString("name"))
        assertTrue(catalog.node(catalog.selected).getBoolean("favorite"))
        assertEquals("disconnected", repository.state.value.connection)
        assertFalse(EncryptedStore(ui.activity).load()!!.has("pending"))
        ui.onAllNodesWithText("Restart fixture").assertAny(hasText("Restart fixture"))
    }
}

/** Process death immediately after the real encrypted journal write, before commit. */
class AndroidJournalSeedE2E {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()
    @Test fun leaveInterruptedEncryptedTransaction() {
        assertTrue(BuildConfig.DEBUG && android.os.Build.MODEL.contains("sdk_gphone"))
        ui.waitUntil(10_000) { !ui.activity.repository.state.value.loading }
        val committed = Catalog(runBlocking { ui.activity.repository.execute("read") })
        val candidate = committed.copy()
        candidate.node(candidate.selected).put("name", "Uncommitted candidate")
        val store = EncryptedStore(ui.activity)
        store.save(obj("journalVersion" to 1, "committed" to committed.data, "pending" to candidate.data))
        assertTrue(store.load()!!.has("pending"))
        assertEquals("Restart fixture", Catalog(ui.activity.repository.state.value.catalog).node(committed.selected).getString("name"))
    }
}

// Minimal entries encoded from common/geodata/geodat.proto. Two categories
// make reduction observable independently of the reducer implementation.
private fun field(tag: Int, bytes: ByteArray) = byteArrayOf(tag.toByte(), bytes.size.toByte()) + bytes
internal fun site(code: String, domain: String): ByteArray {
    val value = byteArrayOf(8, 3) + field(18, domain.toByteArray())
    return field(10, field(10, code.toByteArray()) + field(18, value))
}
private fun varint(value: Int): ByteArray {
    val out = java.io.ByteArrayOutputStream(); var rest = value
    while (rest >= 0x80) { out.write(rest and 0x7f or 0x80); rest = rest ushr 7 }
    out.write(rest); return out.toByteArray()
}
/** [code]'s record, then an unused record of [filler] zero bytes, built in one array. */
internal fun largeSite(code: String, domain: String, filler: Int): ByteArray {
    val head = field(10, "BIG".toByteArray()) + byteArrayOf(122) + varint(filler) // 122: field 15, length-delimited
    val prefix = site(code, domain) + byteArrayOf(10) + varint(head.size + filler) + head
    return prefix.copyOf(prefix.size + filler)
}
internal fun ip(code: String, first: Int) =
    field(10, field(10, code.toByteArray()) + field(18, field(10, byteArrayOf(first.toByte(), 0, 2, 0)) + byteArrayOf(0x10, 24)))

/** Stands in for another app's Parcelable class; the share test renames it inside the parcel. */
private class ForeignParcelable : android.os.Parcelable {
    override fun describeContents() = 0
    override fun writeToParcel(dest: android.os.Parcel, flags: Int) = Unit
}

/** Minimal synthetic local feed; no request leaves the emulator. */
internal class HTTPFixture : AutoCloseable {
    private val server = ServerSocket(0, 16, InetAddress.getByName("127.0.0.1"))
    private val pool = Executors.newCachedThreadPool()
    @Volatile var body = ""
    @Volatile var binary: ByteArray? = null
    @Volatile var headers = emptyMap<String, String>()
    /** Answers with a redirect there instead of the body. */
    @Volatile var redirect: String? = null
    /** Milliseconds to hold each response, so a test can act while a download runs. */
    @Volatile var stall = 0L
    /** The HTTP status of every answer; an error status sends no body. */
    @Volatile var status = 200
    /** Sent as the ETag; a request naming it in If-None-Match gets 304 Not Modified, counted in [notModified]. */
    @Volatile var etag: String? = null
    val notModified = java.util.concurrent.atomic.AtomicInteger()
    val requests = java.util.concurrent.atomic.AtomicInteger()
    /** The X-HWID of the latest request, by path and query. */
    val hwids = java.util.concurrent.ConcurrentHashMap<String, String>()
    val url = "http://127.0.0.1:${server.localPort}/feed"
    init { pool.submit { while (!server.isClosed) { val socket = runCatching { server.accept() }.getOrNull() ?: break; pool.submit { respond(socket) } } } }
    private fun respond(socket: Socket) = socket.use {
        requests.incrementAndGet()
        it.soTimeout = 5000
        val input = it.getInputStream().bufferedReader()
        val target = input.readLine().orEmpty().split(" ").getOrElse(1) { "" }
        var match = ""
        while (true) {
            val line = input.readLine()
            if (line.isNullOrEmpty()) break
            if (line.startsWith("x-hwid:", ignoreCase = true)) hwids[target] = line.substringAfter(':').trim()
            if (line.startsWith("if-none-match:", ignoreCase = true)) match = line.substringAfter(':').trim()
        }
        if (stall > 0) Thread.sleep(stall)
        val tag = etag
        if (tag != null && match == tag) {
            notModified.incrementAndGet()
            it.getOutputStream().write("HTTP/1.1 304 Not Modified\r\nETag: $tag\r\nConnection: close\r\n\r\n".toByteArray()); return@use
        }
        redirect?.let { target -> it.getOutputStream().write("HTTP/1.1 302 Found\r\nLocation: $target\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray()); return@use }
        val bytes = if (status != 200) ByteArray(0) else binary ?: body.toByteArray()
        val header = "HTTP/1.1 $status ${if (status == 200) "OK" else "Error"}\r\nContent-Type: text/plain\r\nContent-Length: ${bytes.size}\r\nConnection: close\r\n" +
            (headers + listOfNotNull(tag?.let { "ETag" to it })).entries.joinToString("") { entry -> "${entry.key}: ${entry.value}\r\n" } + "\r\n"
        it.getOutputStream().write(header.toByteArray()); it.getOutputStream().write(bytes)
    }
    override fun close() { server.close(); pool.shutdownNow() }
}
