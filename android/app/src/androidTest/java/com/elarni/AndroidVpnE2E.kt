package com.elarni

import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.lifecycle.Lifecycle
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.*
import org.json.JSONArray
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.io.DataInputStream
import java.net.*
import java.util.concurrent.Executors

/** Actual VpnService traffic from two distinct app UIDs to disposable local peers. */
class AndroidVpnE2E {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()
    private lateinit var launchIntent: android.content.Intent
    private val repo get() = ui.activity.repository
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val httpPort get() = InstrumentationRegistry.getArguments().getString("httpPort")!!.toInt()
    private val udpPort get() = InstrumentationRegistry.getArguments().getString("udpPort")!!.toInt()
    private fun call(command: String, args: JSONObject = JSONObject()) = runBlocking { repo.execute(command, args) }
    private fun snapshot() = Catalog(call("read"))
    // A cleartext loopback feed needs destination approval before any request.
    private val reviewFeed = "http://127.0.0.1:9/review-fixture"
    @Before fun prepare() {
        launchIntent = android.content.Intent(ui.activity.intent)
        assertTrue(BuildConfig.DEBUG && android.os.Build.MODEL.contains("sdk_gphone"))
        assertTrue(httpPort in 1024..65535 && udpPort in 1024..65535)
        ui.waitUntil(10_000) { !repo.state.value.loading }
        repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
        call("reject")
        snapshot().sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        snapshot().routes.forEach { call("deleteRouting", obj("id" to it.getString("id"))) }
        call("settings", obj("settings" to Settings.defaults()))
        // Liveness probes the recovery targets when there are any; an earlier test's would be counted as traffic.
        call("automation", obj("configuration" to Automation.defaults()))
        // The liveness check goes through the selected server; SocksFixture answers it and leaves it out of its count.
        // An address, not a name: resolving a name sends a counted DNS query through the server.
        Automation.livenessTargets = JSONArray(listOf(obj("id" to "fixture", "url" to "http://$LIVENESS_ADDRESS/", "expectedStatus" to 200, "expectedBody" to "proxy:elarni-synthetic")))
    }
    @After fun cleanup() {
        Automation.livenessTargets = Automation.defaultTargets
        ui.runOnUiThread { ui.activity.intent = launchIntent }
        repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
    }
    private fun connect() {
        ui.runOnUiThread { ui.activity.connect() }
        ui.waitUntil(15_000) {
            val root = instrumentation.uiAutomation.rootInActiveWindow
            for (label in listOf("OK", "Allow")) root?.findAccessibilityNodeInfosByText(label)?.firstOrNull { it.isClickable && it.packageName?.toString() != "com.elarni.debug" }?.performAction(AccessibilityNodeInfo.ACTION_CLICK)
            repo.state.value.connection in listOf("connected", "failed") &&
                runCatching { ui.activityRule.scenario.state == Lifecycle.State.RESUMED }.getOrDefault(false)
        }
        assertEquals("Connection error: ${repo.state.value.error}", "connected", repo.state.value.connection)
    }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    /** Whether the fixture app's last request had the VPN as its network. */
    private var inTunnel = false
    private fun traffic(identity: String, mode: String, port: Int, address: String = "10.0.2.2", proxyAddress: String = "", proxyPort: Int = 0, expectReply: Boolean = true): String {
        val token = newId()
        val packageName = "com.elarni.traffic.$identity"
        val proxy = if (proxyPort == 0) "" else " --es proxyAddress $proxyAddress --ei proxyPort $proxyPort"
        // A fast fixture may finish before its first frame; Android 11's -W
        // launch wait can then remain blocked. The token below proves completion.
        shell("am start -n $packageName/com.elarni.traffic.TrafficActivity --es token $token --es mode $mode --es address $address --ei port $port$proxy")
        var result: JSONObject? = null
        // Two direct TCP tries of 4 s connect and 4 s read each fit (TrafficActivity).
        ui.waitUntil(20_000) {
            result = runCatching { JSONObject(shell("run-as $packageName cat files/result.json")) }.getOrNull()
            result?.string("token") == token
        }
        if (expectReply && !result!!.optBoolean("success")) {
            println("VPN failure routes: ${call("routeTable")}")
            println("VPN platform state: ${shell("dumpsys vpn_management")}")
            println("Connectivity state: ${shell("dumpsys connectivity")}")
        }
        if (expectReply) assertTrue("$identity $mode traffic failed: $result; engine=${repo.engine.running}, connection=${repo.state.value.connection}", result!!.optBoolean("success"))
        // The separate UID writes its result before finishing its Activity. Wait for
        // that real transition, including the return from the system permission UI.
        ui.waitUntil(10_000) {
            runCatching { ui.activityRule.scenario.state == Lifecycle.State.RESUMED }.getOrDefault(false)
        }
        inTunnel = result!!.optBoolean("vpn")
        return result!!.optString("body")
    }

    /** Waits until the VPN is connected over a Wi-Fi path that has held for 1.5 s. */
    private fun awaitConnectedOnWiFi() {
        val connectivity = ui.activity.getSystemService(android.net.ConnectivityManager::class.java)
        var stablePath: Long? = null
        var stableSince = android.os.SystemClock.elapsedRealtime()
        ui.waitUntil(30_000) {
            val network = repo.engine.physical()
            val path = network?.networkHandle
            val wifiReady = connectivity.getNetworkCapabilities(network)
                ?.hasTransport(android.net.NetworkCapabilities.TRANSPORT_WIFI) == true
            val time = android.os.SystemClock.elapsedRealtime()
            if (!wifiReady || repo.state.value.connection != "connected" || path != stablePath) {
                stablePath = path; stableSince = time; false
            } else time - stableSince >= 1500
        }
    }

    @Test fun systemInfoLeavesAnotherAppsVpn() {
        val other = "com.elarni.traffic.b"
        fun otherVpn() = java.net.NetworkInterface.getNetworkInterfaces().asSequence().any { it.inetAddresses.asSequence().any { address -> address.hostAddress == "10.111.0.1" } }
        // Both apps hold VPN consent; Android then lets either take the VPN from the other.
        shell("appops set ${ui.activity.packageName} ACTIVATE_VPN allow")
        shell("appops set $other ACTIVATE_VPN allow")
        try {
            shell("am start -n $other/com.elarni.traffic.TrafficActivity --es mode vpn")
            ui.waitUntil(10_000) { otherVpn() }
            ui.waitUntil(10_000) { runCatching { ui.activityRule.scenario.state == Lifecycle.State.RESUMED }.getOrDefault(false) }
            val info = call("systemInfo")
            Thread.sleep(1000)
            assertTrue("Reading system info took the VPN from another app", otherVpn())
            assertTrue("System info no longer reports the VPN consent", info.optBoolean("vpnConsent"))
        } finally {
            shell("am force-stop $other")
            shell("appops set $other ACTIVATE_VPN default")
        }
    }
    @Test fun assignedRoutingControlsVpnTrafficAndBrandedActivation() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Routing%20fixture"))
            val node = snapshot().nodes.single().getString("id")
            val source = snapshot().sources.single().getString("id")
            call("select", obj("id" to node))
            val profile = obj("Name" to "VPN routing", "DomainStrategy" to "IPIfNonMatch",
                "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "DirectSites" to JSONArray(listOf("full:fixture.elarni.test")))
            call("saveRouting", obj("text" to profile.toString()))
            val route = snapshot().routes.single().getString("id")
            assertTrue(snapshot().route(route).getBoolean("enabled"))
            assertEquals(0, snapshot().assignments.length())
            connect()
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            call("assignRouting", obj("id" to source, "routeId" to route))
            assertEquals("IPIfNonMatch", snapshot().compile(node, ui.activity).getJSONObject("routing").getString("domainStrategy"))
            assertTrue(traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
            call("enableRouting", obj("id" to route, "value" to false))
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            call("enableRouting", obj("id" to route, "value" to true))
            assertTrue(traffic("b", "tcp", httpPort).contains("direct:elarni-synthetic"))
            profile.put("DirectSites", JSONArray()).put("BlockSites", JSONArray(listOf("full:fixture.elarni.test")))
            call("saveRouting", obj("id" to route, "text" to profile.toString()))
            val requests = upstream.requests
            assertEquals("Blocked domain must reach neither peer", "", traffic("a", "tcp", httpPort, expectReply = false))
            assertEquals(requests, upstream.requests)
            assertEquals("connected", repo.state.value.connection)
            profile.put("BlockSites", JSONArray()).put("ProxySites", JSONArray(listOf("full:fixture.elarni.test")))
            call("saveRouting", obj("id" to route, "text" to profile.toString()))
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            call("import", obj("text" to "elarni://routing/off"))
            assertEquals(0, snapshot().assignments.length())
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            profile.put("ProxySites", JSONArray()).put("DirectSites", JSONArray(listOf("full:fixture.elarni.test"))).put("DirectIp", JSONArray(listOf("10.0.2.2/32")))
            val encoded = android.util.Base64.encodeToString(profile.toString().toByteArray(), android.util.Base64.NO_WRAP)
            call("import", obj("text" to "elarni://routing/onadd/$encoded"))
            assertEquals(route, snapshot().assignments.getString(source))
            assertTrue(traffic("b", "tcp", httpPort).contains("direct:elarni-synthetic"))
            assertEquals("direct:elarni-udp-fixture", traffic("b", "udp", udpPort))
            repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
            connect()
            assertTrue(traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
        }
    }

    @Test fun connectionRecordingFollowsTheSwitchAndExports() {
        if (!BuildConfig.ELARNI_RECORDING) {
            // A build without the option has no recorder to start, whatever the setting says.
            assertFalse(Native.call("diagnostics", obj("action" to "status")).getBoolean("enabled"))
            assertTrue(Settings.fields.none { it.key == "recordDiagnostics" })
            return
        }
        java.io.File(ui.activity.noBackupFilesDir, "diagnostics").deleteRecursively()
        SocksFixture().use { upstream ->
            val profile = obj("remarks" to "Recorded SOCKS upstream", "outbounds" to JSONArray(listOf(obj("protocol" to "socks", "settings" to obj("servers" to JSONArray(listOf(obj("address" to "127.0.0.1", "port" to upstream.port))))))))
            call("import", obj("text" to profile.toString()))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            connect()
            assertFalse(Native.call("diagnostics", obj("action" to "status")).getBoolean("collecting"))
            repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
            assertEquals("recording_empty", (runCatching { repo.engine.exportRecording() }.exceptionOrNull() as? AppFailure)?.code)
            call("settings", obj("settings" to obj("recordDiagnostics" to true)))
            connect()
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            repo.engine.markRecording()
            repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
            val text = StringBuilder()
            java.util.zip.ZipInputStream(repo.engine.exportRecording().inputStream()).use { zip -> while (zip.nextEntry != null) text.append(zip.readBytes().toString(Charsets.UTF_8)) }
            for (event in listOf("collector_started", "core_start", "outbound_done", "user_stall_marker")) assertTrue("missing $event", text.contains(event))
            // Metadata only: neither the peer nor the upstream address may appear.
            for (address in listOf("10.0.2.2", "127.0.0.1")) assertFalse("recording names $address", text.contains(address))
        }
    }

    @Test fun tuicProtectedTransportBothRelaysAndRestart() {
        for (mode in listOf("native", "quic")) {
            call("import", obj("text" to tuicFixtureProfile("TUIC $mode fixture", mode).toString()))
            val node = snapshot().nodes.single { it.string("name") == "TUIC $mode fixture" }
            assertEquals(mode, node.getJSONObject("config").objects("outbounds").first().getJSONObject("settings").getString("udpRelayMode"))
            call("select", obj("id" to node.getString("id")))
            call("settings", obj("settings" to obj("monitoringEnabled" to true)))
            repeat(2) {
                connect()
                // The physical TUIC endpoint is excluded; the controlled payload
                // destinations are different IPs and must traverse VpnService.
                // A TCP reply without the proxy's body came once in CI; name what came instead.
                traffic("a", "tcp", httpPort, "198.18.0.81").let { assertTrue("TUIC $mode IPv4 TCP body: $it", it.contains("proxy:elarni-synthetic")) }
                assertEquals("proxy:elarni-udp-fixture", traffic("b", "udp", udpPort, "198.18.0.81"))
                traffic("b", "tcp", httpPort, "fdfe:dcba:9876::10").let { assertTrue("TUIC $mode IPv6 TCP body: $it", it.contains("proxy:elarni-synthetic")) }
                assertEquals("proxy:elarni-udp-fixture", traffic("a", "udp", udpPort, "fdfe:dcba:9876::10"))
                assertEquals("198.18.0.81", traffic("a", "dns", udpPort, "198.18.0.81"))
                assertTrue(traffic("b", "systemDns", udpPort).contains("198.18.0.81"))
                ui.waitUntil(6000) { repo.state.value.metrics.optLong("uplinkBytes") > 0 && repo.state.value.metrics.optLong("downlinkBytes") > 0 }
                repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                assertFalse(Native.call("getXrayState").getBoolean("running"))
                assertTrue(traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
            }
        }
    }
    @Test fun vpnUidRoutingRollbackAndLocalProxy() {
        val installed = call("apps").objects("apps").map { it.getString("package") }
        assertTrue("Network apps without launcher activities must be selectable", installed.containsAll(listOf("com.elarni.traffic.a", "com.elarni.traffic.b")))
        SocksFixture().use { upstream ->
            val profile = obj("remarks" to "Synthetic SOCKS upstream", "outbounds" to JSONArray(listOf(obj("protocol" to "socks", "settings" to obj("servers" to JSONArray(listOf(obj("address" to "127.0.0.1", "port" to upstream.port))))))))
            call("import", obj("text" to profile.toString()))
            val id = snapshot().nodes.single().getString("id")
            call("select", obj("id" to id))
            call("settings", obj("settings" to obj("monitoringEnabled" to true)))
            assertTrue("Direct peer must be reachable before VPN startup", traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
            connect()
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            assertEquals("proxy:elarni-udp-fixture", traffic("a", "udp", udpPort))
            assertEquals("198.18.0.81", traffic("a", "dns", udpPort))
            assertTrue("Android's resolver must use the tunnel's synthetic DNS answer", traffic("a", "systemDns", udpPort).contains("198.18.0.81"))
            // Automatic Private DNS upgrades a public resolver such as 1.1.1.1 to DNS-over-TLS, which skips the tunnel's port-53 DNS.
            assertEquals(listOf("198.51.100.254", "fdfe:dcba:9876::2").map(InetAddress::getByName),
                call("routeTable").objects("networks").single { it.getBoolean("vpn") }.strings("dns").map(InetAddress::getByName))
            assertTrue(traffic("a", "tcp", httpPort, "fdfe:dcba:9876::10").contains("proxy:elarni-synthetic"))
            assertEquals("proxy:elarni-udp-fixture", traffic("a", "udp", udpPort, "fdfe:dcba:9876::10"))
            assertTrue(traffic("b", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            ui.waitUntil(6000) { repo.state.value.metrics.optLong("uplinkBytes") > 0 && repo.state.value.metrics.optLong("downlinkBytes") > 0 }
            val connectedMetrics = Native.call("getRuntimeMetrics")
            assertTrue(connectedMetrics.getLong("uplinkBytes") > 0)
            // Without saved credentials, VPN mode still refuses other apps on its SOCKS listener.
            Socket("127.0.0.1", snapshot().settings.getInt("socksPort")).use { socket ->
                socket.soTimeout = 2000; socket.getOutputStream().write(byteArrayOf(5, 1, 0))
                val input = DataInputStream(socket.getInputStream()); assertEquals(5, input.readUnsignedByte()); assertEquals(255, input.readUnsignedByte())
            }
            val internal = call("ping", obj("id" to id, "protocol" to "activeProxy", "url" to "http://10.0.2.2:$httpPort/fixture", "method" to "GET", "timeout" to 5, "expectedStatus" to 200, "expectedBody" to "proxy:elarni-synthetic"))
            assertEquals("success", internal.objects("results").single().getString("status"))
            call("settings", obj("settings" to obj("theme" to "dark", "sort" to "alphabet", "probeTimeout" to 7, "probeMode" to "tcp")))
            assertEquals("connected", repo.state.value.connection)
            assertTrue("Preference saves must preserve the running core's traffic counters", Native.call("getRuntimeMetrics").getLong("uplinkBytes") >= connectedMetrics.getLong("uplinkBytes"))
            // The app is outside its own VPN, so a direct TCP test runs while connected and leaves the tunnel alone.
            ui.runOnIdle { ui.activity.testServers(listOf(id)) }
            ui.waitUntil(10_000) { repo.state.value.pings[id]?.string("protocol") == "tcp" }
            assertEquals("success", repo.state.value.pings.getValue(id).string("status"))
            assertEquals("connected", repo.state.value.connection)
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            call("settings", obj("settings" to obj("excludedRoutes" to JSONArray(listOf("10.0.2.2/32")))))
            assertTrue("Excluded route must bypass the tunnel", traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
            assertEquals("proxy:elarni-udp-fixture", traffic("a", "udp", udpPort, "fdfe:dcba:9876::10"))
            call("settings", obj("settings" to obj("excludedRoutes" to JSONArray(listOf("172.16.0.0/12", "fc00::/7")))))
            assertTrue("Excluded private ranges must keep the tunnel's resolvers", traffic("a", "systemDns", udpPort).contains("198.18.0.81"))
            // Subtracting these leaves loopback and IPv4-mapped prefixes, which VpnService rejects.
            call("settings", obj("settings" to obj("excludedRoutes" to JSONArray(listOf("126.0.0.0/8", "::/128", "::fffe:0:0/96")))))
            assertEquals("connected", repo.state.value.connection)
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            call("settings", obj("settings" to obj("excludedRoutes" to JSONArray())))
            call("settings", obj("settings" to obj("perAppMode" to "bypass", "perAppProcesses" to JSONArray(listOf("com.elarni.traffic.a")))))
            assertTrue("Bypass must reach the direct fixture", traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
            assertFalse("A bypassed app must stay out of the tunnel", inTunnel)
            assertTrue("Unlisted app must retain proxy routing", traffic("b", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            assertTrue(inTunnel)
            // A listed app can take its own target instead of the mode's: a server from any subscription, a local proxy, or a block.
            SocksFixture().use { other -> SocksFixture().use { local ->
                val servers = JSONArray(listOf(obj("address" to "127.0.0.1", "port" to other.port)))
                call("import", obj("text" to obj("remarks" to "Second SOCKS upstream", "outbounds" to JSONArray(listOf(obj("protocol" to "socks", "settings" to obj("servers" to servers))))).toString()))
                val secondID = snapshot().nodes.single { it.getString("id") != id }.getString("id")
                fun target(value: String) = call("settings", obj("settings" to obj("perAppTargets" to obj("com.elarni.traffic.a" to value))))
                target("node:$secondID")
                val selectedRequests = upstream.requests
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                assertTrue("An app with its own target must enter the tunnel", inTunnel)
                assertTrue("The app's own server must carry its traffic", other.requests > 0)
                assertEquals("The app's traffic must skip the selected server", selectedRequests, upstream.requests)
                assertTrue(traffic("b", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                assertTrue("Unlisted apps keep the selected server", upstream.requests > selectedRequests)
                target("proxy:socks5://127.0.0.1:${local.port}")
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                assertTrue("The app's local proxy must carry its traffic", local.requests > 0)
                target("block")
                assertFalse("A blocked app must not reach the network", traffic("a", "tcp", httpPort, expectReply = false).contains("elarni-synthetic"))
                call("settings", obj("settings" to obj("perAppTargets" to JSONObject())))
                // While connected, another server's test runs its own core beside the VPN and leaves the selection alone.
                call("settings", obj("settings" to obj("probeMode" to "proxy", "probeURL" to "http://10.0.2.2:$httpPort/fixture", "probeExpectedStatus" to 200, "probeExpectedBody" to "proxy:elarni-synthetic")))
                val tested = other.requests
                ui.runOnIdle { ui.activity.testServers(listOf(secondID)) }
                ui.waitUntil(15_000) { repo.state.value.pings.containsKey(secondID) }
                assertEquals("success", repo.state.value.pings.getValue(secondID).string("status"))
                assertTrue("The test must reach the other server", other.requests > tested)
                assertEquals(id, snapshot().selected)
                assertEquals("connected", repo.state.value.connection)
                call("deleteNode", obj("id" to secondID))
            } }
            call("settings", obj("settings" to obj("perAppMode" to "proxyOnly")))
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            assertTrue(inTunnel)
            // The connections view names the app per-app routing found, by UID, and the rule that took it.
            val listedUid = ui.activity.packageManager.getApplicationInfo("com.elarni.traffic.a", 0).uid.toString()
            val listed = Native.call("readConnections", obj("epoch" to 0, "after" to 0)).objects("connections")
                .lastOrNull { it.string("name") == listedUid && it.optInt("port") == httpPort }
            assertNotNull("The connections view must name the listed app", listed)
            assertEquals("found", listed!!.string("owner"))
            assertTrue(listed.strings("rules").contains("elarni-per-app-listed"))
            assertEquals("proxy", listed.string("kind"))
            assertTrue("Only-listed mode must send other apps directly", traffic("b", "tcp", httpPort).contains("direct:elarni-synthetic"))
            assertFalse("Only-listed mode must keep other apps out of the tunnel", inTunnel)
            assertEquals("direct:elarni-udp-fixture", traffic("b", "udp", udpPort))
            ui.activityRule.scenario.recreate()
            assertEquals("connected", repo.state.value.connection)
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            val before = snapshot().settings.getInt("socksPort")
            ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { occupied ->
                try { call("settings", obj("settings" to obj("socksPort" to occupied.localPort))); fail("Occupied port must reject transaction") } catch (_: AppFailure) { }
            }
            assertEquals(before, snapshot().settings.getInt("socksPort"))
            assertEquals("connected", repo.state.value.connection)
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
            assertFalse(Native.call("getXrayState").getBoolean("running"))
            assertTrue(traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
            call("settings", obj("settings" to obj("perAppMode" to "off", "xrayTunEnabled" to false)))
            call("credentials", obj("username" to "fixture-user", "password" to "fixture-password"))
            call("settings", obj("settings" to obj("inboundAuthEnabled" to true, "allowLAN" to true, "httpInboundEnabled" to true)))
            connect()
            assertTrue("Local proxy must leave system traffic direct", traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
            val connectivity = ui.activity.getSystemService(android.net.ConnectivityManager::class.java)
            val localAddress = connectivity.getLinkProperties(repo.engine.physical())!!.linkAddresses.first { it.address is Inet4Address }.address.hostAddress!!
            assertTrue(traffic("a", "socksProxy", httpPort, proxyAddress = localAddress, proxyPort = before).contains("proxy:elarni-synthetic"))
            assertTrue(traffic("b", "httpProxy", httpPort, proxyAddress = localAddress, proxyPort = snapshot().settings.getInt("httpPort")).contains("proxy:elarni-synthetic"))
            Socket("127.0.0.1", before).use { socket ->
                socket.soTimeout = 2000; socket.getOutputStream().write(byteArrayOf(5, 1, 0))
                val input = DataInputStream(socket.getInputStream()); assertEquals(5, input.readUnsignedByte()); assertEquals(255, input.readUnsignedByte())
            }
            val result = call("ping", obj("id" to id, "protocol" to "activeProxy", "url" to "http://10.0.2.2:$httpPort/fixture", "method" to "GET", "timeout" to 5, "expectedStatus" to 200, "expectedBody" to "proxy:elarni-synthetic"))
            assertEquals("success", result.objects("results").single().getString("status"))
            assertTrue(upstream.requests > 0)
        }
    }

    @Test fun vpnLifecycleRecoveryAndRapidRequests() {
        SocksFixture().use { upstream ->
            val profile = obj("remarks" to "Lifecycle fixture", "outbounds" to JSONArray(listOf(obj("protocol" to "socks", "settings" to obj("servers" to JSONArray(listOf(obj("address" to "127.0.0.1", "port" to upstream.port))))))))
            call("import", obj("text" to profile.toString()))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            call("settings", obj("settings" to obj("onDemandEnabled" to true, "disconnectOnSleep" to true)))
            connect()
            // Crash recovery and resume run on the applied catalog while a destination approval stays open.
            val sources = snapshot().sources.size
            val warning = call("import", obj("text" to reviewFeed)).getJSONObject("warning")
            Native.call("stopXray")
            ui.waitUntil(15_000) { repo.state.value.connection == "connected" && Native.call("getXrayState").optBoolean("running") }
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            try {
                shell("input keyevent 223")
                ui.waitUntil(10_000) { repo.state.value.connection == "paused" }
                assertFalse(Native.call("getXrayState").getBoolean("running"))
            } finally { shell("input keyevent 224"); shell("wm dismiss-keyguard") }
            ui.waitUntil(15_000) { repo.state.value.connection == "connected" }
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            assertEquals(warning.getString("token"), repo.state.value.approval?.string("token"))
            assertEquals(sources, snapshot().sources.size)
            call("reject")
            // A queued connect cannot supersede the user's later Stop. A new
            // Connect after Stop must survive the old service's destruction.
            repeat(8) {
                ui.runOnUiThread { ui.activity.connect(); repo.requestStop() }
                ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                Thread.sleep(600)
                assertFalse(Native.call("getXrayState").getBoolean("running"))
                connect()
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            }
            val owner = repo.engine.service!!
            owner.onRevoke()
            ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" && repo.engine.service == null }
            assertFalse(Native.call("getXrayState").getBoolean("running"))
            assertFalse(snapshot().data.optBoolean("connectionIntent"))
            assertEquals("vpn_revoked", repo.state.value.error)
            assertTrue(traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
        }
    }

    @Test fun routingEditThatCannotStartKeepsTheTunnel() {
        fun tunnel() = NetworkInterface.getNetworkInterfaces().asSequence().first { it.inetAddresses.asSequence().any { address -> address.hostAddress == "198.51.100.253" } }.index
        SocksFixture().use { upstream -> HTTPFixture().use { feed ->
            feed.binary = ip("US", 198)
            val profile = obj("Name" to "Running route", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8",
                "Geoipurl" to feed.url, "UseChunkFiles" to "true", "ProxyIp" to JSONArray(listOf("geoip:us")))
            call("saveRouting", obj("text" to profile.toString()))
            val route = snapshot().routes.single().getString("id")
            var result = call("refreshGeofiles", obj("id" to route))
            while (result.has("warning")) result = call("approveResource", obj("token" to result.getJSONObject("warning").getString("token")))
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Running%20route"))
            call("assignRouting", obj("id" to snapshot().sources.single().getString("id"), "routeId" to route))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            connect()
            val before = tunnel()
            // The edit needs a code the geofile lacks and fails before the core could change, so the running tunnel stays.
            try { call("saveRouting", obj("id" to route, "text" to profile.put("ProxyIp", JSONArray(listOf("geoip:us", "geoip:missing"))).toString())); fail("A missing code must reject the edit") }
            catch (error: AppFailure) { assertEquals("missing_geodata:geoip:missing", error.code) }
            assertEquals("connected", repo.state.value.connection)
            assertEquals("The failed edit replaced the running tunnel", before, tunnel())
            assertTrue(Native.call("getXrayState").getBoolean("running"))
        } }
    }
    // Android and the per-app rules take a listed app's UID when the tunnel starts; removing or installing it while
    // connected builds the tunnel again, so the app installed meanwhile takes its route at once.
    @Test fun listedAppRemovedAndInstalledWhileConnectedTakesItsRoute() {
        fun tunnel() = NetworkInterface.getNetworkInterfaces().asSequence().firstOrNull { it.inetAddresses.asSequence().any { address -> address.hostAddress == "198.51.100.253" } }?.index
        fun rebuilt(before: Int?) = ui.waitUntil(15_000) { repo.state.value.connection == "connected" && tunnel().let { it != null && it != before } }
        val listed = "com.elarni.traffic.a"
        val copy = "/data/local/tmp/elarni-listed-app.apk"
        fun installed() = shell("pm list packages $listed").lines().any { it.trim() == "package:$listed" }
        assertTrue(shell("cp ${shell("pm path $listed").trim().removePrefix("package:")} $copy").isBlank())
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Listed%20app"))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            call("settings", obj("settings" to obj("perAppMode" to "proxyOnly", "perAppProcesses" to JSONArray(listOf(listed)))))
            try {
                connect()
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                assertTrue(inTunnel)
                var before = tunnel()
                assertTrue(shell("pm uninstall $listed").contains("Success"))
                rebuilt(before)
                before = tunnel()
                assertTrue(shell("pm install -r $copy").contains("Success"))
                rebuilt(before)
                assertTrue("The app installed while connected must take its route", traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                assertTrue("Only-listed mode must take the installed app into the tunnel", inTunnel)
                assertTrue("Other apps must stay out", traffic("b", "tcp", httpPort).contains("direct:elarni-synthetic"))
                assertFalse(inTunnel)
            } finally {
                if (!installed()) shell("pm install -r $copy")
                shell("rm $copy")
            }
        }
    }
    // A restore clears the connection intent, so it waits for Disconnect instead of leaving the running VPN unrecorded.
    @Test fun restoreWhileConnectedAsksToDisconnectFirst() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Restore%20fixture"))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            val backup = call("backup", obj("password" to "synthetic backup password")).getString("text")
            connect()
            try { call("restore", obj("text" to backup, "password" to "synthetic backup password")); fail("A restore ran while connected") }
            catch (error: AppFailure) { assertEquals("disconnect_first", error.code) }
            assertEquals("connected", repo.state.value.connection)
            assertTrue(snapshot().data.optBoolean("connectionIntent"))
        }
    }
    // A start the user did not ask for, like the one after the system killed this process, must leave a VPN another app started meanwhile.
    @Test fun restartLeavesAVpnAnotherAppStarted() {
        val other = "com.elarni.traffic.b"
        fun otherVpn() = NetworkInterface.getNetworkInterfaces().asSequence().any { it.inetAddresses.asSequence().any { address -> address.hostAddress == "10.111.0.1" } }
        shell("appops set ${ui.activity.packageName} ACTIVATE_VPN allow")
        shell("appops set $other ACTIVATE_VPN allow")
        SocksFixture().use { upstream ->
            try {
                call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Restart%20fixture"))
                call("select", obj("id" to snapshot().nodes.single().getString("id")))
                // A failed start leaves the Connect recorded without a service, as a killed process does.
                ServerSocket(snapshot().settings.getInt("socksPort"), 1, InetAddress.getByName("127.0.0.1")).use {
                    runBlocking { repo.requestConnect() }
                    ui.waitUntil(15_000) { repo.state.value.connection == "disconnected" && repo.engine.service == null }
                }
                assertTrue(snapshot().data.optBoolean("connectionIntent"))
                shell("am start -n $other/com.elarni.traffic.TrafficActivity --es mode vpn")
                // The restart looks in ConnectivityManager for another app's VPN, listed a moment after its interface exists.
                val connectivity = ui.activity.getSystemService(android.net.ConnectivityManager::class.java)
                ui.waitUntil(10_000) { otherVpn() && connectivity.allNetworks.any { network ->
                    connectivity.getNetworkCapabilities(network)?.let { it.hasTransport(android.net.NetworkCapabilities.TRANSPORT_VPN) && it.ownerUid != android.os.Process.myUid() } == true
                } }
                ui.waitUntil(10_000) { runCatching { ui.activityRule.scenario.state == Lifecycle.State.RESUMED }.getOrDefault(false) }
                ui.activity.startForegroundService(android.content.Intent(ui.activity, ElarniVpnService::class.java))
                Thread.sleep(3000)
                assertTrue("A restart took the VPN from another app", otherVpn())
                assertNotEquals("connected", repo.state.value.connection)
            } finally {
                shell("am force-stop $other")
                shell("appops set $other ACTIVATE_VPN default")
            }
        }
    }
    // Android starts an always-on VPN before establish(), while isAlwaysOn() still reads false; that start overrides an earlier Disconnect.
    @Test fun alwaysOnStartAfterDisconnectConnects() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Always-on%20fixture"))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            connect()
            repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" && repo.engine.service == null }
            assertFalse(snapshot().data.optBoolean("connectionIntent"))
            // The system's always-on start carries the VpnService action.
            ui.activity.startForegroundService(android.content.Intent(VpnService.SERVICE_INTERFACE).setClass(ui.activity, ElarniVpnService::class.java))
            runCatching { ui.waitUntil(15_000) { repo.state.value.connection == "connected" } }
            assertEquals("An always-on start after Disconnect stayed down", "connected", repo.state.value.connection)
            assertTrue(snapshot().data.optBoolean("connectionIntent"))
        }
    }
    @Test fun failClosedTunnelEndsWithItsReason() {
        fun tunnelUp() = NetworkInterface.getNetworkInterfaces().asSequence().any { it.inetAddresses.asSequence().any { address -> address.hostAddress == "198.51.100.253" } }
        SocksFixture().use { upstream ->
            for (reason in listOf("server removed", "recovery turned off")) {
                call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Held"))
                call("select", obj("id" to snapshot().nodes.single().getString("id")))
                call("settings", obj("settings" to obj("onDemandEnabled" to true)))
                connect()
                // A taken SOCKS port fails every restart, so recovery holds the interface and drops traffic.
                ServerSocket().use { blocker ->
                    Native.call("stopXray")
                    blocker.bind(InetSocketAddress("127.0.0.1", snapshot().settings.getInt("socksPort")))
                    ui.waitUntil(15_000) { repo.state.value.connection == "failed" }
                    assertTrue(tunnelUp())
                    if (reason == "server removed") call("deleteSource", obj("id" to snapshot().sources.single().getString("id")))
                    else call("settings", obj("settings" to obj("onDemandEnabled" to false)))
                    runCatching { ui.waitUntil(10_000) { !tunnelUp() } }
                    assertFalse("The fail-closed tunnel outlived its reason: $reason", tunnelUp())
                }
                assertTrue(traffic("a", "tcp", httpPort).contains("direct:elarni-synthetic"))
                repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                snapshot().sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
            }
        }
    }

    @Test fun busyCancelKeepsAQueuedDisconnect() {
        SocksFixture().use { upstream -> ServerSocket(0, 4, InetAddress.getByName("127.0.0.1")).use { silent ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Primary\nsocks://127.0.0.1:${silent.localPort}#Silent"))
            val nodes = snapshot().nodes
            call("select", obj("id" to nodes.first { it.string("name") == "Primary" }.getString("id")))
            connect()
            // A probe through a server that never answers holds the catalog lock, so Disconnect queues behind it.
            val slow = nodes.first { it.string("name") == "Silent" }.getString("id")
            val probe = Executors.newSingleThreadExecutor().submit {
                runCatching { call("ping", obj("id" to slow, "protocol" to "proxy", "url" to "http://10.0.2.2:$httpPort/", "timeout" to 10, "expectedStatus" to 200, "expectedBody" to "")) }
            }
            ui.waitUntil(5_000) { repo.state.value.busy }
            // Disconnect, then the busy bar's Cancel.
            ui.runOnUiThread { repo.requestStop(); repo.cancel() }
            probe.get(15, java.util.concurrent.TimeUnit.SECONDS)
            runCatching { ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" } }
            assertEquals("Cancel dropped the queued Disconnect", "disconnected", repo.state.value.connection)
            assertFalse(Native.call("getXrayState").getBoolean("running"))
        } }
    }

    @Test fun automaticFallbackUsesRealHealthResponses() {
        // Three failed probes 30 s apart would spend 90 s waiting; the policy is the same at 1 s.
        Automation.healthInterval = 1.0
        try { SocksFixture(503).use { first -> SocksFixture().use { second ->
            call("import", obj("text" to "socks://127.0.0.1:${first.port}#Primary\nsocks://127.0.0.1:${second.port}#Fallback"))
            val catalog = snapshot()
            val primary = catalog.nodes.first { it.string("name") == "Primary" }.getString("id")
            val fallback = catalog.nodes.first { it.string("name") == "Fallback" }.getString("id")
            call("select", obj("id" to primary))
            call("automation", obj("configuration" to obj("schemaVersion" to 1, "enabled" to true, "policy" to "orderedFallback",
                "subscriptionID" to catalog.sources.single().getString("id"), "nodeIDs" to JSONArray(listOf(primary, fallback)),
                "targets" to JSONArray(listOf(obj("id" to "fixture", "url" to "http://10.0.2.2:$httpPort/health", "expectedStatus" to 200, "expectedBody" to "proxy:elarni-synthetic"))))))
            // Health checks and failover run while a destination review stays open; failover applies only its own change.
            call("import", obj("text" to reviewFeed)).getJSONObject("warning")
            connect()
            ui.waitUntil(30_000) { repo.state.value.catalog.string("selectedNodeId") == fallback && repo.state.value.connection == "connected" }
            assertEquals(1, snapshot().sources.size)
            assertTrue(first.requests >= 3)
            assertTrue(second.requests > 0)
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
            runBlocking { repo.tick() }
            assertFalse(Native.call("getXrayState").getBoolean("running"))
        } } } finally { Automation.healthInterval = 30.0 }
    }

    @Test fun healthNeedsOnlyOnePassingTarget() {
        Automation.healthInterval = 1.0
        try { SocksFixture().use { first -> SocksFixture().use { second ->
            call("import", obj("text" to "socks://127.0.0.1:${first.port}#Primary\nsocks://127.0.0.1:${second.port}#Fallback"))
            val catalog = snapshot()
            val primary = catalog.nodes.first { it.string("name") == "Primary" }.getString("id")
            val fallback = catalog.nodes.first { it.string("name") == "Fallback" }.getString("id")
            call("select", obj("id" to primary))
            // The second target never serves its expected body; desktop and macOS stay while any target passes.
            call("automation", obj("configuration" to obj("schemaVersion" to 1, "enabled" to true, "policy" to "orderedFallback",
                "subscriptionID" to catalog.sources.single().getString("id"), "nodeIDs" to JSONArray(listOf(primary, fallback)),
                "targets" to JSONArray(listOf(obj("id" to "fixture", "url" to "http://10.0.2.2:$httpPort/health", "expectedStatus" to 200, "expectedBody" to "proxy:elarni-synthetic"),
                    obj("id" to "unreachable", "url" to "http://198.18.0.99/health", "expectedStatus" to 200, "expectedBody" to "never served"))))))
            connect()
            // A server that passed is checked again only once traffic leaves: a SOCKS greeting to the listener counts.
            val socks = snapshot().settings.getInt("socksPort")
            fun send() { runCatching { Socket("127.0.0.1", socks).use { it.soTimeout = 2000; it.getOutputStream().write(byteArrayOf(5, 1, 0)); it.getInputStream().read() } } }
            ui.waitUntil(30_000) { send(); repo.state.value.catalog.string("selectedNodeId") != primary || first.requests >= 6 }
            assertEquals("One failing target switched servers", primary, repo.state.value.catalog.string("selectedNodeId"))
            assertEquals("connected", repo.state.value.connection)
            // With the primary gone, the fallback qualifies on the target that still answers.
            first.close()
            ui.waitUntil(30_000) { send(); repo.state.value.catalog.string("selectedNodeId") == fallback && repo.state.value.connection == "connected" }
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
        } } } finally { Automation.healthInterval = 30.0 }
    }

    @Test fun connectedSaysWhenTheServerPassesNoTraffic() {
        Automation.livenessInterval = 1.0
        Automation.livenessTargets = JSONArray(listOf(obj("id" to "fixture", "url" to "http://10.0.2.2:$httpPort/health", "expectedStatus" to 200, "expectedBody" to "proxy:elarni-synthetic")))
        try {
            val port = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
            call("import", obj("text" to "socks://127.0.0.1:$port#Gone"))
            // "connected" means only that the core runs; a server that passes nothing must say so.
            connect()
            ui.waitUntil(20_000) { repo.state.value.liveness == "noTraffic" }
            assertEquals("connected", repo.state.value.connection)
            // Home and the notification say so.
            val manager = ui.activity.getSystemService(android.app.NotificationManager::class.java)
            fun notified(text: String) = manager.activeNotifications.any { it.id == 1 && it.notification.extras.getString(android.app.Notification.EXTRA_TEXT) == text }
            ui.waitUntil(5000) { notified("VPN connected · server passes no traffic") }
            ui.waitUntil(5000) { ui.onAllNodesWithText("Connected · no traffic").fetchSemanticsNodes().isNotEmpty() }
            // A failed check is repeated each interval and clears once traffic passes.
            SocksFixture(port = port).use {
                ui.waitUntil(20_000) { repo.state.value.liveness == "ok" }
                ui.waitUntil(5000) { notified("VPN connected") && ui.onAllNodesWithText("Connected").fetchSemanticsNodes().isNotEmpty() }
            }
            // The server is gone again while traffic still leaves. Listener replies and direct
            // routes keep the downlink moving without it, so they cannot keep it "ok".
            val socks = snapshot().settings.getInt("socksPort")
            ui.waitUntil(20_000) {
                Socket("127.0.0.1", socks).use { it.soTimeout = 2000; it.getOutputStream().write(byteArrayOf(5, 1, 0)); assertEquals(5, it.getInputStream().read()) }
                repo.state.value.liveness == "noTraffic"
            }
        } finally { Automation.livenessInterval = 60.0; Automation.livenessTargets = Automation.defaultTargets }
    }

    @Test fun connectedReviewsPreferencesAndServerRemoval() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Removal%20fixture"))
            val node = snapshot().nodes.single().getString("id")
            call("select", obj("id" to node))
            // An approval built before Connect would undo it: approving it later saved connectionIntent=false.
            val warning = call("import", obj("text" to reviewFeed)).getJSONObject("warning")
            connect()
            val refused = try { call("approveSource", obj("token" to warning.getString("token"))); "approved" } catch (error: AppFailure) { error.code }
            assertEquals("approval_expired", refused)
            assertTrue(snapshot().data.optBoolean("connectionIntent"))
            // Settings the running core does not read keep it, and with it every connection and counter.
            assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
            ui.waitUntil(6000) { Native.call("getRuntimeMetrics").optLong("uplinkBytes") > 0 }
            for (value in listOf(true, false)) {
                val counted = Native.call("getRuntimeMetrics").getLong("uplinkBytes")
                call("settings", obj("settings" to obj("onDemandEnabled" to value, "disconnectOnSleep" to value, "monitoringEnabled" to value, "launchAtBoot" to value,
                    "logLevel" to if (value) "debug" else "warning")))
                assertEquals("connected", repo.state.value.connection)
                assertEquals(if (value) "debug" else "warning", Native.call("readLogs").getString("level"))
                assertTrue("Preference saves must keep the running core", Native.call("getRuntimeMetrics").getLong("uplinkBytes") >= counted)
            }
            // Deleting the connected server stops the service, and its notification goes with it.
            val manager = ui.activity.getSystemService(android.app.NotificationManager::class.java)
            ui.waitUntil(5000) { manager.activeNotifications.any { it.id == 1 } }
            call("deleteNode", obj("id" to node))
            ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" && repo.engine.service == null }
            ui.waitUntil(5000) { manager.activeNotifications.none { it.id == 1 } }
            assertFalse(snapshot().data.optBoolean("connectionIntent"))
        }
    }

    @Test fun homeWidgetShowsSpeedAndControlsTheConnection() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Widget%20fixture"))
            val node = snapshot().nodes.single().getString("id")
            call("select", obj("id" to node))
            val context = ui.activity.applicationContext
            shell("appops set ${context.packageName} ACTIVATE_VPN allow")
            // A launcher holds this grant; the test's own host binds the widget as a launcher would.
            // The user is uid / 100000; "--user current" gets the command killed on API 30 and 36.
            shell("appwidget grantbind --package ${context.packageName} --user ${android.os.Process.myUid() / 100_000}")
            val manager = android.appwidget.AppWidgetManager.getInstance(context)
            val host = android.appwidget.AppWidgetHost(context, 4242)
            ui.runOnUiThread { host.startListening() }
            try {
                val id = host.allocateAppWidgetId()
                assertTrue("Widget not bound", manager.bindAppWidgetIdIfAllowed(id, android.content.ComponentName(context, ConnectionWidget::class.java)))
                val view = ui.runOnUiThread { host.createView(context, id, manager.getAppWidgetInfo(id)) }
                // The host applies each update the app sends; null is a hidden line.
                fun text(viewId: Int) = ui.runOnUiThread { view.findViewById<android.widget.TextView>(viewId)?.takeIf { it.visibility == android.view.View.VISIBLE }?.text?.toString() }
                fun press() = ui.runOnUiThread { assertTrue(view.findViewById<android.view.View>(R.id.widget_button).performClick()) }
                ui.waitUntil(10_000) { text(R.id.widget_status) == "Disconnected" && text(R.id.widget_button) == "Connect" }
                assertEquals("Widget fixture", text(R.id.widget_server))
                assertNull(text(R.id.widget_speed))
                press()
                ui.waitUntil(15_000) { repo.state.value.connection == "connected" && text(R.id.widget_status) == "Connected" && text(R.id.widget_button) == "Disconnect" }
                assertTrue(snapshot().data.optBoolean("connectionIntent"))
                // Live traffic monitoring stays off: a widget on screen is reason enough to read the counters.
                assertFalse(snapshot().settings.optBoolean("monitoringEnabled"))
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                ui.waitUntil(10_000) { text(R.id.widget_speed)?.matches(Regex("^↓ (?!0 B/s).+/s · ↑ .+/s$")) == true }
                press()
                ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" && text(R.id.widget_status) == "Disconnected" && text(R.id.widget_speed) == null }
                assertFalse(snapshot().data.optBoolean("connectionIntent"))
                // Without a server, the button opens the app to choose one.
                call("deleteNode", obj("id" to node))
                ui.waitUntil(10_000) { text(R.id.widget_status) == "Choose a server in Elarni" && text(R.id.widget_server) == null && text(R.id.widget_button) == "Open" }
                press()
                ui.waitUntil(10_000) { ui.activity.intent.action == "com.elarni.OPEN_CONNECT" }
            } finally {
                // Deleting first: API 30's stopListening throws on a widget id that was never bound.
                host.deleteHost()
                ui.runOnUiThread { host.stopListening() }
            }
        }
    }

    @Test fun untrustedWiFiConnectsOncePerJoin() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Wi-Fi%20fixture"))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            val context = ui.activity.applicationContext
            shell("appops set ${context.packageName} ACTIVATE_VPN allow")
            listOf("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION").forEach { shell("pm grant ${context.packageName} android.permission.$it") }
            shell("cmd location set-location-enabled true")
            assertTrue(WiFiRule.namesAllowed(context))
            // The emulator's access point; Wi-Fi coming back joins it again as a new network.
            fun network() = Regex("connected to \"(.+?)\"").find(shell("cmd wifi status"))?.groupValues?.get(1)
            ui.waitUntil(30_000) { network() != null }
            val ssid = network()!!
            val seen = context.getSharedPreferences("wifi-rule", android.content.Context.MODE_PRIVATE)
            seen.edit().clear().commit()
            fun join() = seen.getString("join", null)
            // After a few quick toggles Android may hold back autojoin (API 30 did); joining by name does not wait for it.
            fun wifiOn() {
                shell("cmd wifi set-wifi-enabled enabled"); ui.waitUntil(10_000) { shell("cmd wifi status").contains("Wifi is enabled") }
                shell("cmd wifi connect-network $ssid open"); ui.waitUntil(30_000) { network() != null }
            }
            fun rejoin(): String? {
                val before = join()
                shell("cmd wifi set-wifi-enabled disabled"); ui.waitUntil(15_000) { network() == null }
                wifiOn()
                return before
            }
            fun rule(on: Boolean, trusted: List<String>) = call("settings", obj("settings" to obj("connectOnUntrustedWiFi" to on, "trustedWiFiNetworks" to JSONArray(trusted))))
            try {
                // Turning it on counts the network already joined; a trusted one stays as it is.
                rule(true, listOf(ssid))
                ui.waitUntil(15_000) { join() != null }
                assertEquals("disconnected", repo.state.value.connection)
                // On Wi-Fi, Android reports leaving it; that report asks for the next join. Both reach a killed process.
                // Mobile data stays foreground for a while after Wi-Fi comes back, as after an earlier run's last join;
                // WiFiRule.arm looks again every 5 s for up to 2 minutes, so wait as long as it does.
                ui.waitUntil(125_000) { WiFiRule.watching == "leave" }
                rule(true, emptyList())
                var before = rejoin()
                ui.waitUntil(15_000) { join() != before }
                ui.waitUntil(15_000) { repo.state.value.connection == "connected" }
                assertTrue(snapshot().data.optBoolean("connectionIntent"))
                // The join connects while the default network still moves from mobile data to Wi-Fi.
                awaitConnectedOnWiFi()
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                // A Disconnect holds on this network, even when the rule reads the network again.
                repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                runBlocking { WiFiRule.arm(context as ElarniApplication) }
                assertEquals("disconnected", repo.state.value.connection)
                // In the background, the next join connects: VPN consent allows the service to start. Mobile data
                // stays foreground for a while after a join, and leaving is watched once it drops back.
                ui.waitUntil(125_000) { WiFiRule.watching == "leave" }
                shell("input keyevent KEYCODE_HOME")
                before = rejoin()
                ui.waitUntil(15_000) { join() != before }
                ui.waitUntil(15_000) { repo.state.value.connection == "connected" }
                repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                rule(true, listOf(ssid))
                before = rejoin()
                ui.waitUntil(15_000) { join() != before }
                Thread.sleep(2000)
                assertEquals("A trusted join stays disconnected", "disconnected", repo.state.value.connection)
                // Turning the rule on counts the network already joined as a new join.
                rule(false, emptyList()); rule(true, emptyList())
                ui.waitUntil(15_000) { repo.state.value.connection == "connected" }
                repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                rule(false, emptyList())
                ui.waitUntil(5000) { WiFiRule.watching == null }
                before = rejoin()
                Thread.sleep(3000)
                assertEquals("Off, joins go unread", before, join())
                assertEquals("disconnected", repo.state.value.connection)
            } finally {
                // Later tests need Wi-Fi joined; the test's own failure, if any, stays the one reported.
                runCatching { wifiOn() }
                rule(false, emptyList())
                // ActivityScenario tracks lifecycle by its MAIN/LAUNCHER launch Intent.
                shell("am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n ${context.packageName}/com.elarni.MainActivity")
                ui.runOnUiThread { ui.activity.intent = launchIntent }
                ui.waitUntil(5000) { ui.activityRule.scenario.state == Lifecycle.State.RESUMED }
            }
        }
    }

    @Test fun launcherShortcutsAndOtherAppsControlTheConnection() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Shortcut%20fixture"))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            val context = ui.activity.applicationContext
            shell("appops set ${context.packageName} ACTIVATE_VPN allow")
            // A long press on the launcher icon offers these; the launcher starts them as Elarni, without a link confirmation.
            val shortcuts = context.getSystemService(android.content.pm.ShortcutManager::class.java).dynamicShortcuts.associateBy { it.id }
            assertEquals(setOf("connect", "disconnect"), shortcuts.keys)
            context.startActivity(android.content.Intent(shortcuts.getValue("connect").intent).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            ui.waitUntil(15_000) { repo.state.value.connection == "connected" }
            context.startActivity(android.content.Intent(shortcuts.getValue("disconnect").intent).addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK))
            ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
            assertFalse(snapshot().data.optBoolean("connectionIntent"))
            // Automation apps send explicit broadcasts while Elarni is in the background. am broadcast returns once the receiver finishes.
            fun send(action: String, key: String = snapshot().data.string("externalControlKey")) = assertTrue(shell("am broadcast -a com.elarni.action.$action -n ${context.packageName}/com.elarni.RemoteControl" +
                (if (key.isEmpty()) "" else " --es key $key")).contains("Broadcast completed"))
            shell("input keyevent KEYCODE_HOME")
            try {
                send("CONNECT")
                assertEquals("Other apps control the connection only once allowed", "disconnected", repo.state.value.connection)
                assertFalse(snapshot().data.optBoolean("connectionIntent"))
                call("settings", obj("settings" to obj("allowExternalControl" to true)))
                val first = snapshot().data.string("externalControlKey")
                assertTrue("Allowing other apps makes their key", first.length >= 22)
                call("newControlKey")
                val second = snapshot().data.string("externalControlKey")
                assertNotEquals(first, second)
                val events = repo.state.value.event
                // Broadcasts without the current key are ignored, and quietly: the user did nothing wrong.
                for (key in listOf("", "wrong", first)) {
                    send("CONNECT", key)
                    assertEquals("A broadcast with the key \"$key\" connected", "disconnected", repo.state.value.connection)
                }
                assertEquals(events, repo.state.value.event)
                call("settings", obj("settings" to obj("allowExternalControl" to false)))
                call("settings", obj("settings" to obj("allowExternalControl" to true)))
                assertEquals("Turning the setting off and on keeps the key", second, snapshot().data.string("externalControlKey"))
                send("CONNECT"); ui.waitUntil(15_000) { repo.state.value.connection == "connected" }
                send("TOGGLE"); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                send("TOGGLE"); ui.waitUntil(15_000) { repo.state.value.connection == "connected" }
                send("DISCONNECT"); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                assertFalse(snapshot().data.optBoolean("connectionIntent"))
            } finally {
                // ActivityScenario tracks lifecycle by its MAIN/LAUNCHER launch Intent.
                shell("am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n ${context.packageName}/com.elarni.MainActivity")
                ui.runOnUiThread { ui.activity.intent = launchIntent }
                ui.waitUntil(5000) { ui.activityRule.scenario.state == Lifecycle.State.RESUMED }
            }
        }
    }

    @Test fun platformTileNotificationAndNetworkRecovery() {
        SocksFixture().use { upstream ->
            call("import", obj("text" to "socks://127.0.0.1:${upstream.port}#Platform%20fixture"))
            call("select", obj("id" to snapshot().nodes.single().getString("id")))
            call("settings", obj("settings" to obj("onDemandEnabled" to true)))
            connect()
            val tile = "com.elarni.debug/com.elarni.ElarniTileService"
            // SystemUI's QS dump shows Tile.STATE_INACTIVE as 1 and STATE_ACTIVE as 2, after the tile's label.
            fun tileState(): Pair<String, String>? {
                val dump = shell("dumpsys activity service com.android.systemui")
                return Regex("spec=custom\\(${Regex.escape(tile)}\\).*?,label=(.*?),.*?,state=(\\d)").find(dump)?.let { it.groupValues[2] to it.groupValues[1] }
                    // Android 11 dumps no tile specs. Its QS log lists updates oldest first and keeps
                    // earlier runs, so read the newest update since the last click.
                    ?: Regex("custom\\(${Regex.escape(tile)}\\)\\] Tile updated\\. Label=(.*?)\\. State=(\\d)")
                        .findAll(dump.substringAfterLast("custom($tile)] Tile clicked")).lastOrNull()?.let { it.groupValues[2] to it.groupValues[1] }
            }
            // While on, the tile names the server in use.
            fun awaitTile(connection: String, state: String, label: String, timeout: Long) = try {
                ui.waitUntil(timeout) { repo.state.value.connection == connection && tileState() == (state to label) }
            } catch (error: androidx.compose.ui.test.ComposeTimeoutException) {
                val lines = shell("dumpsys activity service com.android.systemui").lines().filter { "ElarniTile" in it }.takeLast(4)
                throw AssertionError("Wanted $connection with tile state $state and label $label: connection=${repo.state.value.connection} " +
                    "tile=${tileState()} error=${repo.state.value.error} SystemUI: $lines", error)
            }
            shell("cmd statusbar add-tile $tile")
            try {
                // From the home screen, Android 14+ limits background foreground-service starts.
                shell("input keyevent KEYCODE_HOME")
                shell("cmd statusbar expand-settings")
                Thread.sleep(800)
                shell("cmd statusbar click-tile $tile")
                awaitTile("disconnected", "1", "Elarni", 10_000)
                shell("cmd statusbar click-tile $tile")
                awaitTile("connected", "2", "Platform fixture", 15_000)
                // With consent granted, the tile connects in place instead of opening the app.
                assertTrue(ui.activity.intent.action != "com.elarni.OPEN_CONNECT")
                shell("cmd statusbar collapse")
                // ActivityScenario tracks lifecycle by its MAIN/LAUNCHER launch Intent.
                shell("am start -W -a android.intent.action.MAIN -c android.intent.category.LAUNCHER -n ${ui.activity.packageName}/com.elarni.MainActivity")
                ui.runOnUiThread { ui.activity.intent = launchIntent }
                ui.waitUntil(5000) { ui.activityRule.scenario.state == Lifecycle.State.RESUMED }
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                val manager = ui.activity.getSystemService(android.app.NotificationManager::class.java)
                ui.waitUntil(5000) { manager.activeNotifications.any {
                    it.id == 1 && it.notification.extras.getString(android.app.Notification.EXTRA_TEXT) == "VPN connected"
                } }
                val notification = manager.activeNotifications.single { it.id == 1 }.notification
                assertEquals("VPN connected", notification.extras.getString(android.app.Notification.EXTRA_TEXT))
                notification.actions.single { it.title.toString() == "Disconnect" }.actionIntent.send()
                ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
                ui.waitUntil(5000) { manager.activeNotifications.none { it.id == 1 } }
                assertFalse(snapshot().data.optBoolean("connectionIntent"))
                connect()
                // The core follows the network while a destination approval stays open.
                val warning = call("import", obj("text" to reviewFeed)).getJSONObject("warning")
                val connectivity = ui.activity.getSystemService(android.net.ConnectivityManager::class.java)
                fun online() = connectivity.allNetworks.any { network -> connectivity.getNetworkCapabilities(network)?.let {
                    it.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_INTERNET) && it.hasCapability(android.net.NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                } == true }
                try {
                    shell("cmd connectivity airplane-mode enable")
                    shell("svc wifi disable")
                    ui.waitUntil(20_000) { !online() }
                    assertTrue(snapshot().data.optBoolean("connectionIntent"))
                } finally {
                    shell("cmd connectivity airplane-mode disable")
                    shell("svc wifi enable")
                }
                // Cellular can recover seconds before Wi-Fi associates, and the core then starts there. Require the
                // default network on the Wi-Fi path we just restored, which the core's new sockets follow without
                // a restart while cellular stays, then verify uninterrupted traffic.
                awaitConnectedOnWiFi()
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                assertEquals(warning.getString("token"), repo.state.value.approval?.string("token"))
                assertEquals(1, snapshot().sources.size)
                call("reject")
                try {
                    assertTrue(shell("cmd deviceidle force-idle").contains("idle", ignoreCase = true))
                    assertTrue(Native.call("getXrayState").getBoolean("running"))
                } finally { shell("cmd deviceidle unforce") }
                assertTrue(traffic("a", "tcp", httpPort).contains("proxy:elarni-synthetic"))
                // A local server has nothing to refresh, so no background job starts the app (AndroidE2E checks one that does).
                val scheduler = ui.activity.getSystemService(android.app.job.JobScheduler::class.java)
                assertNull(scheduler.getPendingJob(ElarniApplication.REFRESH_JOB))
            } finally {
                shell("cmd statusbar collapse")
                shell("cmd statusbar remove-tile $tile")
            }
        }
    }

    /** Through the host's TUIC peer, so the core's own connection rides the physical network. Returns the
     *  milliseconds until a proxied reply once [ready] holds, failing after a minute. */
    private fun recoveryMillis(ready: () -> Boolean = { true }): Long {
        val start = android.os.SystemClock.elapsedRealtime()
        val connectivity = ui.activity.getSystemService(android.net.ConnectivityManager::class.java)
        while (true) {
            val path = ready(); val connection = repo.state.value.connection
            val reply = if (!path || connection != "connected") "" else
                runCatching { traffic("a", "tcp", httpPort, address = "198.18.0.81", expectReply = false) }.getOrElse { "failed: $it" }
            if (reply.contains("proxy:elarni-synthetic")) return android.os.SystemClock.elapsedRealtime() - start
            assertTrue("No proxied reply a minute after the change: path=$path connection=$connection reply=$reply " +
                "device network=${connectivity.getNetworkCapabilities(repo.engine.physical())} core network=${connectivity.getNetworkCapabilities(repo.engine.network)} " +
                "error=${repo.state.value.error}",
                android.os.SystemClock.elapsedRealtime() - start < 60_000)
            Thread.sleep(250)
        }
    }
    /** CPU milliseconds of this process: the app with its VPN service and core, and this test's own little loop. */
    private fun cpuMillis(): Long {
        // utime and stime are fields 14 and 15; the name in parentheses may hold spaces.
        val fields = java.io.File("/proc/self/stat").readText().substringAfterLast(')').trim().split(' ')
        return (fields[11].toLong() + fields[12].toLong()) * 1000 / android.system.Os.sysconf(android.system.OsConstants._SC_CLK_TCK)
    }
    private fun measured(text: String) {
        println("elarni measurement: $text")
        instrumentation.sendStatus(0, android.os.Bundle().apply { putString("elarni-measurement", text) })
    }

    /** The running core's sockets follow the new default network; with "Reconnect automatically" on, the
     *  repository also restarts the core when its network is gone. Either way traffic must come back within 30 s. */
    @Test fun wifiToMobileDataHandoverCarriesTraffic() {
        call("import", obj("text" to tuicFixtureProfile("Handover fixture", "native").toString()))
        call("select", obj("id" to snapshot().nodes.single().getString("id")))
        val connectivity = ui.activity.getSystemService(android.net.ConnectivityManager::class.java)
        fun on(network: android.net.Network?, transport: Int) = connectivity.getNetworkCapabilities(network)?.hasTransport(transport) == true
        val wifi = android.net.NetworkCapabilities.TRANSPORT_WIFI; val cellular = android.net.NetworkCapabilities.TRANSPORT_CELLULAR
        fun ssid() = Regex("connected to \"(.+?)\"").find(shell("cmd wifi status"))?.groupValues?.get(1)
        ui.waitUntil(30_000) { ssid() != null }
        val ssid = ssid()!!
        connect()
        recoveryMillis { on(repo.engine.physical(), wifi) }
        try {
            val results = mutableListOf<String>()
            for (reconnect in listOf(false, true)) {
                call("settings", obj("settings" to obj("onDemandEnabled" to reconnect)))
                shell("cmd wifi set-wifi-enabled disabled")
                val toMobile = recoveryMillis { on(repo.engine.physical(), cellular) && (!reconnect || on(repo.engine.network, cellular)) }
                shell("cmd wifi set-wifi-enabled enabled"); shell("cmd wifi connect-network $ssid open")
                val toWiFi = recoveryMillis { on(repo.engine.physical(), wifi) }
                results += "reconnect ${if (reconnect) "on" else "off"}: to mobile data $toMobile ms, back to Wi-Fi $toWiFi ms"
                assertTrue("Wi-Fi to mobile data took $toMobile ms with reconnect $reconnect", toMobile < 30_000)
            }
            measured("handover (API ${android.os.Build.VERSION.SDK_INT}) " + results.joinToString("; "))
        } finally {
            // Later tests need Wi-Fi joined; the test's own failure, if any, stays the one reported.
            runCatching { shell("cmd wifi set-wifi-enabled enabled"); shell("cmd wifi connect-network $ssid open"); ui.waitUntil(30_000) { ssid() != null } }
        }
    }

    /** A phone left on a table: screen off and Doze with the VPN up for sleepMinutes (10 unless the runner
     *  passes another; fractions allowed), then the time from waking to a proxied reply. The VPN must not go down meanwhile. */
    @Test fun screenOffInDozeThenWakeCarriesTraffic() {
        val minutes = InstrumentationRegistry.getArguments().getString("sleepMinutes")?.toDouble() ?: 10.0
        call("import", obj("text" to tuicFixtureProfile("Sleep fixture", "native").toString()))
        call("select", obj("id" to snapshot().nodes.single().getString("id")))
        connect()
        recoveryMillis()
        // 20 connected seconds with the app on screen and no traffic, scaled to a minute: the cost of the UI, the service and the core idling.
        val idleStart = cpuMillis(); Thread.sleep(20_000)
        val idle = (cpuMillis() - idleStart) * 3; val idlePss = android.os.Debug.getPss() / 1024
        val states = mutableSetOf<String>()
        var asleep = 0L; var asleepPss = 0L
        try {
            shell("dumpsys battery unplug")
            shell("input keyevent KEYCODE_SLEEP")
            assertTrue(shell("cmd deviceidle force-idle").contains("idle", ignoreCase = true))
            val sleepStart = cpuMillis()
            val until = android.os.SystemClock.elapsedRealtime() + (minutes * 60_000).toLong()
            while (android.os.SystemClock.elapsedRealtime() < until) { states += repo.state.value.connection; Thread.sleep(1000) }
            asleep = cpuMillis() - sleepStart; asleepPss = android.os.Debug.getPss() / 1024
        } finally {
            shell("cmd deviceidle unforce"); shell("dumpsys battery reset")
            shell("input keyevent KEYCODE_WAKEUP"); shell("wm dismiss-keyguard")
        }
        val wake = recoveryMillis()
        measured("wake to traffic after $minutes min in Doze: $wake ms; states while asleep $states; app CPU $idle ms in an idle minute on screen, " +
            "${(asleep / minutes).toLong()} ms per minute asleep; PSS $idlePss MiB idle, $asleepPss MiB asleep (API ${android.os.Build.VERSION.SDK_INT})")
        assertFalse("The VPN went down while the screen was off: $states", "disconnected" in states)
        assertTrue("Waking took $wake ms to carry traffic", wake < 30_000)
    }
}

/** The host's disposable TUIC peer; unlike an in-process fixture, it outlives the app process. */
private fun tuicFixtureProfile(name: String, mode: String): JSONObject {
    val arguments = InstrumentationRegistry.getArguments()
    val certificate = String(android.util.Base64.decode(arguments.getString("tuicCertificate"), android.util.Base64.DEFAULT))
    return obj("remarks" to name, "outbounds" to JSONArray(listOf(obj("protocol" to "tuic", "tag" to "proxy",
        "settings" to obj("address" to "10.0.2.2", "port" to arguments.getString("tuicPort")!!.toInt(), "uuid" to "00000000-0000-4000-8000-000000000001", "password" to "synthetic-tuic-only", "udpRelayMode" to mode),
        "streamSettings" to obj("security" to "tls", "tlsSettings" to obj("serverName" to "tuic-fixture.example", "alpn" to JSONArray(listOf("h3")), "disableSystemRoot" to true,
            "certificates" to JSONArray(listOf(obj("usage" to "verify", "certificate" to JSONArray(certificate.lines()))))))))))
}

/** Pairs of processes. The system kills the first with the VPN up, as battery managers do in sleep, and the next process start restores it
 *  without the user; a process that dies after its service ended leaves the VPN down. A crash is restored too, but not a second one soon after. */
class AndroidProcessDeathE2E {
    private val instrumentation get() = InstrumentationRegistry.getInstrumentation()
    private val repo get() = (instrumentation.targetContext.applicationContext as ElarniApplication).repository
    private fun call(command: String, args: JSONObject = JSONObject()) = runBlocking { repo.execute(command, args) }
    private fun shell(command: String) = ParcelFileDescriptor.AutoCloseInputStream(instrumentation.uiAutomation.executeShellCommand(command)).bufferedReader().use { it.readText() }
    private fun waitFor(millis: Long, condition: () -> Boolean): Boolean {
        val deadline = android.os.SystemClock.elapsedRealtime() + millis
        while (!condition()) { if (android.os.SystemClock.elapsedRealtime() > deadline) return false; Thread.sleep(100) }
        return true
    }
    /** Only the tunnel reaches the payload destination, through the TUIC peer. */
    private fun proxied(): Boolean {
        val token = newId(); val fixture = "com.elarni.traffic.a"
        shell("am start -n $fixture/com.elarni.traffic.TrafficActivity --es token $token --es mode tcp --es address 198.18.0.81 --ei port ${InstrumentationRegistry.getArguments().getString("httpPort")}")
        var result: JSONObject? = null
        waitFor(10_000) { result = runCatching { JSONObject(shell("run-as $fixture cat files/result.json")) }.getOrNull(); result?.string("token") == token }
        return result?.optString("body")?.contains("proxy:elarni-synthetic") == true
    }
    @Test fun a_connectedProcessIsKilled() {
        assertTrue(BuildConfig.DEBUG && android.os.Build.MODEL.contains("sdk_gphone"))
        runBlocking { repo.awaitReady() }
        Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        call("settings", obj("settings" to Settings.defaults()))
        call("import", obj("text" to tuicFixtureProfile("Process death fixture", "native").toString()))
        call("select", obj("id" to Catalog(call("read")).nodes.single().getString("id")))
        shell("appops set ${instrumentation.targetContext.packageName} ACTIVATE_VPN allow")
        runBlocking { repo.requestConnect() }
        assertTrue("Connection error: ${repo.state.value.error}", waitFor(15_000) { repo.state.value.connection == "connected" })
        assertTrue(proxied())
        // The runner requires this marker before the crash it reports.
        instrumentation.sendStatus(0, android.os.Bundle().apply { putString("elarni", "killed-while-connected") })
        android.os.Process.killProcess(android.os.Process.myPid())
    }
    @Test fun b_vpnReturnsWithoutTheUser() {
        try {
            waitFor(20_000) { repo.state.value.connection == "connected" }
            assertEquals("The VPN stayed down after the system killed its process", "connected", repo.state.value.connection)
            assertTrue(proxied())
        } finally {
            repo.requestStop(); waitFor(10_000) { repo.state.value.connection == "disconnected" }
            Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        }
    }
    @Test fun c_processWithoutTheServiceIsKilled() {
        assertTrue(BuildConfig.DEBUG && android.os.Build.MODEL.contains("sdk_gphone"))
        runBlocking { repo.awaitReady() }
        Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        call("settings", obj("settings" to Settings.defaults()))
        call("import", obj("text" to tuicFixtureProfile("Failed connect fixture", "native").toString()))
        call("select", obj("id" to Catalog(call("read")).nodes.single().getString("id")))
        shell("appops set ${instrumentation.targetContext.packageName} ACTIVATE_VPN allow")
        // A taken SOCKS port fails the start; without recovery the service ends and the Connect stays recorded.
        ServerSocket(Catalog(call("read")).settings.getInt("socksPort"), 1, InetAddress.getByName("127.0.0.1")).use {
            runBlocking { repo.requestConnect() }
            assertTrue(waitFor(15_000) { repo.state.value.connection == "disconnected" && repo.engine.service == null })
        }
        assertTrue(Catalog(call("read")).data.optBoolean("connectionIntent"))
        instrumentation.sendStatus(0, android.os.Bundle().apply { putString("elarni", "killed-without-service") })
        android.os.Process.killProcess(android.os.Process.myPid())
    }
    @Test fun d_vpnStaysDownWithoutItsService() {
        try {
            runBlocking { repo.awaitReady() }
            assertTrue(Catalog(call("read")).data.optBoolean("connectionIntent"))
            assertFalse("A process that ended without the VPN service brought the VPN back",
                waitFor(15_000) { repo.state.value.connection != "disconnected" || repo.engine.service != null })
        } finally {
            repo.requestStop(); waitFor(10_000) { repo.state.value.connection == "disconnected" }
            Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        }
    }
    @Test fun e_processPausedForSleepIsKilled() {
        assertTrue(BuildConfig.DEBUG && android.os.Build.MODEL.contains("sdk_gphone"))
        runBlocking { repo.awaitReady() }
        Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        call("settings", obj("settings" to Settings.defaults().put("disconnectOnSleep", true)))
        call("import", obj("text" to tuicFixtureProfile("Sleep fixture", "native").toString()))
        call("select", obj("id" to Catalog(call("read")).nodes.single().getString("id")))
        shell("appops set ${instrumentation.targetContext.packageName} ACTIVATE_VPN allow")
        shell("input keyevent KEYCODE_WAKEUP")
        runBlocking { repo.requestConnect() }
        assertTrue("Connection error: ${repo.state.value.error}", waitFor(15_000) { repo.state.value.connection == "connected" })
        shell("input keyevent KEYCODE_SLEEP")
        assertTrue("The VPN did not pause when the screen turned off", waitFor(10_000) { repo.state.value.connection == "paused" })
        instrumentation.sendStatus(0, android.os.Bundle().apply { putString("elarni", "killed-while-paused") })
        android.os.Process.killProcess(android.os.Process.myPid())
    }
    @Test fun f_vpnStaysPausedUntilTheScreenTurnsOn() {
        try {
            runBlocking { repo.awaitReady() }
            assertFalse("The next process start reconnected while the screen was off",
                waitFor(15_000) { repo.state.value.connection == "connected" || repo.engine.running })
            shell("input keyevent KEYCODE_WAKEUP"); shell("wm dismiss-keyguard")
            assertTrue("The VPN did not resume when the screen turned on", waitFor(20_000) { repo.state.value.connection == "connected" })
            assertTrue(proxied())
        } finally {
            shell("input keyevent KEYCODE_WAKEUP"); shell("wm dismiss-keyguard")
            repo.requestStop(); waitFor(10_000) { repo.state.value.connection == "disconnected" }
            Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
            call("settings", obj("settings" to Settings.defaults()))
        }
    }
    private fun connectFixture(name: String) {
        assertTrue(BuildConfig.DEBUG && android.os.Build.MODEL.contains("sdk_gphone"))
        runBlocking { repo.awaitReady() }
        Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        call("settings", obj("settings" to Settings.defaults()))
        call("import", obj("text" to tuicFixtureProfile(name, "native").toString()))
        call("select", obj("id" to Catalog(call("read")).nodes.single().getString("id")))
        shell("appops set ${instrumentation.targetContext.packageName} ACTIVATE_VPN allow")
        runBlocking { repo.requestConnect() }
        assertTrue("Connection error: ${repo.state.value.error}", waitFor(15_000) { repo.state.value.connection == "connected" })
        assertTrue(proxied())
    }
    // As an uncaught error does; a Go panic exits the process itself, which is restored the same way.
    private fun crash(marker: String) {
        instrumentation.sendStatus(0, android.os.Bundle().apply { putString("elarni", marker) })
        Thread { throw IllegalStateException("synthetic crash") }.start()
        Thread.sleep(10_000)
    }
    @Test fun g_connectedProcessCrashes() {
        // An earlier run's restore must not count against this one.
        instrumentation.targetContext.getSharedPreferences("watch", android.content.Context.MODE_PRIVATE).edit().clear().commit()
        connectFixture("Crash fixture")
        crash("crashed-while-connected")
    }
    @Test fun h_vpnReturnsAfterACrash() {
        try {
            waitFor(20_000) { repo.state.value.connection == "connected" }
            assertEquals("The VPN stayed down after its process crashed", "connected", repo.state.value.connection)
            assertTrue(proxied())
        } finally {
            repo.requestStop(); waitFor(10_000) { repo.state.value.connection == "disconnected" }
        }
    }
    @Test fun i_restoredProcessCrashesAgain() {
        connectFixture("Crash fixture")
        crash("crashed-again")
    }
    @Test fun j_secondCrashSoonStaysDown() {
        try {
            runBlocking { repo.awaitReady() }
            assertTrue(Catalog(call("read")).data.optBoolean("connectionIntent"))
            assertFalse("A crash within 10 minutes of the last restored one brought the VPN back, so a crash could loop",
                waitFor(15_000) { repo.state.value.connection != "disconnected" || repo.engine.service != null })
        } finally {
            repo.requestStop(); waitFor(10_000) { repo.state.value.connection == "disconnected" }
            Catalog(call("read")).sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
            instrumentation.targetContext.getSharedPreferences("watch", android.content.Context.MODE_PRIVATE).edit().clear().commit()
        }
    }
}

// TEST-NET-1 (RFC 5737): nothing answers it but SocksFixture. Sniffing may name it as a domain.
private const val LIVENESS_ADDRESS = "192.0.2.1"
/** Whether a SOCKS target is one the tests send to: private, benchmark (198.18.0.0/15) or .test, not the liveness
 *  address. Other apps on the emulator (Google Play services) send through the VPN too, to public addresses. */
private fun testDestination(target: ByteArray): Boolean {
    val host = if (target[0].toInt() == 3) String(target, 2, target.size - 2) else null
    if (host != null && !android.net.InetAddresses.isNumericAddress(host)) return host.endsWith(".test")
    val bytes = host?.let { android.net.InetAddresses.parseNumericAddress(it).address } ?: target.copyOfRange(1, target.size)
    val address = InetAddress.getByAddress(bytes)
    return address.isSiteLocalAddress || address.isLoopbackAddress || (bytes.size == 16 && bytes[0].toInt() and 0xfe == 0xfc) ||
        (bytes.size == 4 && bytes[0] == 198.toByte() && bytes[1].toInt() and 0xfe == 18)
}

/** Synthetic SOCKS peer never opens an outbound connection; it answers only local test payloads. */
private class SocksFixture(private val status: Int = 200, port: Int = 0) : AutoCloseable {
    private val listener = ServerSocket(port, 32, InetAddress.getByName("127.0.0.1"))
    private val executor = Executors.newCachedThreadPool()
    private val sockets = java.util.concurrent.ConcurrentLinkedQueue<AutoCloseable>()
    @Volatile var requests = 0
    val port get() = listener.localPort
    init { executor.submit { while (!listener.isClosed) { val socket = runCatching { listener.accept() }.getOrNull() ?: break; sockets.add(socket); executor.submit { runCatching { handle(socket) }; socket.close(); sockets.remove(socket) } } } }
    private fun address(input: DataInputStream): ByteArray {
        val type = input.readUnsignedByte()
        val bytes = ByteArray(when(type) { 1 -> 4; 4 -> 16; 3 -> input.readUnsignedByte(); else -> throw java.io.IOException("address") })
        input.readFully(bytes)
        return byteArrayOf(type.toByte()) + (if (type == 3) byteArrayOf(bytes.size.toByte()) else byteArrayOf()) + bytes
    }
    private fun handle(socket: Socket): Unit = socket.use {
        socket.soTimeout = 10000
        val input = DataInputStream(socket.getInputStream()); val output = socket.getOutputStream()
        if (input.readUnsignedByte() != 5) return
        repeat(input.readUnsignedByte()) { input.readByte() }
        output.write(byteArrayOf(5, 0))
        if (input.readUnsignedByte() != 5) return
        val command = input.readUnsignedByte(); input.readByte(); val target = address(input); input.readUnsignedShort()
        if (command == 1) {
            output.write(byteArrayOf(5,0,0,1,127,0,0,1,0,0))
            val reader = input.bufferedReader()
            while (!reader.readLine().isNullOrEmpty()) { }
            if (testDestination(target)) requests++
            val body = "proxy:elarni-synthetic"
            output.write("HTTP/1.1 $status Fixture\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n$body".toByteArray())
        } else if (command == 3) {
            DatagramSocket(0, InetAddress.getByName("127.0.0.1")).use { relay ->
                sockets.add(relay)
                output.write(byteArrayOf(5,0,0,1,127,0,0,1,(relay.localPort ushr 8).toByte(),relay.localPort.toByte()))
                relay.soTimeout = 1000
                executor.submit {
                    while (!relay.isClosed) {
                        try {
                            val packet = DatagramPacket(ByteArray(65535), 65535); relay.receive(packet)
                            val buffer = packet.data.copyOf(packet.length); val data = DataInputStream(buffer.inputStream())
                            data.readUnsignedShort(); if (data.readUnsignedByte() != 0) continue
                            val address = address(data); val port = data.readUnsignedShort(); val payload = ByteArray(data.available()); data.readFully(payload)
                            val reply = if (payload.size >= 12 && payload[2].toInt() and 0x80 == 0 && payload[5].toInt() == 1) dnsReply(payload) else "proxy:".toByteArray() + payload
                            val encoded = byteArrayOf(0,0,0) + address + byteArrayOf((port ushr 8).toByte(), port.toByte()) + reply
                            relay.send(DatagramPacket(encoded, encoded.size, packet.socketAddress)); if (testDestination(address)) requests++
                        } catch (_: SocketTimeoutException) { } catch (_: Exception) { break }
                    }
                }
                while (input.read() != -1) { }
                sockets.remove(relay)
            }
        }
    }
    private fun dnsReply(query: ByteArray): ByteArray {
        var end = 12
        while (query[end].toInt() != 0) end += 1 + (query[end].toInt() and 255)
        end += 5
        val type = query[end - 3].toInt() and 255
        val answer = if (type == 28) InetAddress.getByName("2001:db8::51").address else byteArrayOf(198.toByte(),18,0,81)
        val reply = query.copyOf(end); reply[2] = 0x81.toByte(); reply[3] = 0x80.toByte(); reply[7] = 1; reply[9] = 0; reply[11] = 0
        return reply + byteArrayOf(0xc0.toByte(),12,0,type.toByte(),0,1,0,0,0,60,0,answer.size.toByte()) + answer
    }
    override fun close() { listener.close(); sockets.forEach { runCatching { it.close() } }; executor.shutdownNow() }
}
