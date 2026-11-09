package com.elarni

import android.content.Intent
import android.net.Uri
import android.view.accessibility.AccessibilityNodeInfo
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.v2.createAndroidComposeRule
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.SemanticsActions
import androidx.compose.ui.semantics.SemanticsNode
import androidx.compose.ui.semantics.SemanticsProperties
import androidx.compose.ui.semantics.getOrNull
import androidx.compose.ui.test.junit4.accessibility.disableAccessibilityChecks
import androidx.compose.ui.test.junit4.accessibility.enableAccessibilityChecks
import com.google.android.apps.common.testing.accessibility.framework.AccessibilityCheckResult
import com.google.android.apps.common.testing.accessibility.framework.integrations.AccessibilityViewCheckException
import com.google.android.apps.common.testing.accessibility.framework.integrations.espresso.AccessibilityValidator
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.height
import androidx.test.platform.app.InstrumentationRegistry
import kotlinx.coroutines.runBlocking
import org.json.JSONArray
import org.json.JSONObject
import org.junit.*
import org.junit.Assert.*
import java.io.File

/** Form/save/review behavior through the production Compose and catalog boundaries. */
class AndroidUIE2E {
    @get:Rule val ui = createAndroidComposeRule<MainActivity>()
    private lateinit var launchIntent: Intent
    private val repo get() = ui.activity.repository
    private fun call(command: String, args: JSONObject = JSONObject()) = runBlocking { repo.execute(command, args) }
    private fun snapshot() = Catalog(call("read"))
    private fun dismissKeyboard() {
        // Dismiss the native IME before scrolling to a button; inset animation
        // after text input/recreation otherwise moves its touch coordinates.
        // Compose dialogs own a separate window, so the Activity token cannot
        // dismiss their IME. Native Back dismisses it without closing the dialog.
        if (ui.onAllNodes(isDialog()).fetchSemanticsNodes().isNotEmpty() &&
            ui.activity.window.decorView.rootWindowInsets?.isVisible(android.view.WindowInsets.Type.ime()) == true) {
            InstrumentationRegistry.getInstrumentation().sendKeyDownUpSync(android.view.KeyEvent.KEYCODE_BACK)
        }
        ui.runOnUiThread {
            val focus = ui.activity.currentFocus ?: ui.activity.window.decorView
            ui.activity.getSystemService(android.view.inputmethod.InputMethodManager::class.java)
                .hideSoftInputFromWindow(focus.windowToken, 0)
            focus.clearFocus()
        }
        ui.waitUntil(5000) { ui.activity.window.decorView.rootWindowInsets?.isVisible(android.view.WindowInsets.Type.ime()) != true }
    }
    private fun click(text: String) {
        dismissKeyboard()
        val match = hasText(text) and hasClickAction()
        if (ui.onAllNodes(match).fetchSemanticsNodes().isEmpty()) ui.onNode(hasScrollToIndexAction()).performScrollToNode(match)
        if (ui.onAllNodes(match and hasAnyAncestor(hasScrollAction())).fetchSemanticsNodes().isNotEmpty()) ui.onNode(match).performScrollTo()
        ui.waitForIdle()
        ui.onNode(match).assertIsDisplayed().performClick()
    }
    // A setting shows its value on a row; the row's dialog edits it.
    private fun editSetting(title: String, value: String) {
        click(title)
        ui.onNode(hasSetTextAction() and hasAnyAncestor(isDialog())).performTextReplacement(value)
        click("OK")
    }
    private fun systemClick(text: String) {
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        try {
            ui.waitUntil(10_000) {
                // A title can repeat the text of the item to click (DocumentsUI's "Downloads"), so try each match.
                automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(text).orEmpty().filter {
                    it.text?.toString().equals(text, ignoreCase = true) || it.contentDescription?.toString().equals(text, ignoreCase = true)
                }.any { node ->
                    // DocumentsUI's accessibility delegate exposes ACTION_CLICK even
                    // when the underlying document row has isClickable=false (API 30).
                    generateSequence(node) { it.parent }.firstOrNull { target ->
                        target.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK }
                    }?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
                }
            }
        } catch (error: androidx.compose.ui.test.ComposeTimeoutException) {
            // Name what the system window showed instead.
            fun texts(node: AccessibilityNodeInfo?): List<String> = if (node == null) emptyList() else
                listOfNotNull(node.text?.toString(), node.contentDescription?.toString()).filter(String::isNotBlank) +
                    (0 until node.childCount).flatMap { texts(node.getChild(it)) }
            val root = automation.rootInActiveWindow
            throw AssertionError("\"$text\" was not clickable in ${root?.packageName}: ${texts(root).take(40)}", error)
        }
    }
    @Before fun prepare() {
        launchIntent = Intent(ui.activity.intent)
        assertTrue(BuildConfig.DEBUG && android.os.Build.MODEL.contains("sdk_gphone"))
        ui.waitUntil(10_000) { !repo.state.value.loading }
        repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
        call("reject")
        snapshot().sources.forEach { call("deleteSource", obj("id" to it.getString("id"))) }
        snapshot().routes.forEach { call("deleteRouting", obj("id" to it.getString("id"))) }
        call("settings", obj("settings" to Settings.defaults()))
        // The QR screen's live scanner needs the camera. A grant leaves the app running; a revoke would end it.
        InstrumentationRegistry.getInstrumentation().uiAutomation.grantRuntimePermission(ui.activity.packageName, android.Manifest.permission.CAMERA)
        if (ui.onAllNodesWithText("Country").fetchSemanticsNodes().isNotEmpty() && ui.onAllNodesWithText("Sort").fetchSemanticsNodes().isNotEmpty())
            ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        listOf("Home", "Subscriptions", "Routing", "Settings").forEach { tab ->
            ui.onNode(hasText(tab) and hasClickAction()).performClick()
            repeat(8) { if (ui.onAllNodesWithContentDescription("Back").fetchSemanticsNodes().isNotEmpty()) ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() } }
        }
        ui.onNode(hasText("Home") and hasClickAction()).performClick()
        ui.onAllNodesWithContentDescription("Dismiss").fetchSemanticsNodes().takeIf { it.isNotEmpty() }?.let { ui.onNodeWithContentDescription("Dismiss").performClick() }
    }
    @After fun cleanup() {
        ui.runOnUiThread { ui.activity.intent = launchIntent }
        repo.requestStop(); ui.waitUntil(10_000) { repo.state.value.connection == "disconnected" }
    }

    @Test fun routingDraftSurvivesRotationAndDuplicate() {
        call("import", obj("text" to "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:18080?encryption=none#UI%20fixture"))
        call("select", obj("id" to snapshot().nodes.single().getString("id")))
        call("saveRouting", obj("text" to obj("Name" to "Editor fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8").toString()))
        val id = snapshot().routes.single().getString("id")
        val source = snapshot().sources.single()
        assertEquals(0, snapshot().assignments.length())
        ui.onNode(hasText("Routing") and hasClickAction()).performClick()
        ui.onNodeWithText("Enabled · Manual · Not assigned").assertExists()
        click("Editor fixture")
        ui.onNodeWithText("Not assigned").assertExists()
        click("Assign to subscription")
        ui.onNodeWithText(source.getString("name")).performClick()
        ui.waitUntil(5000) { snapshot().assignments.string(source.getString("id")) == id }
        ui.onNodeWithText("Assigned to ${source.getString("name")}").assertExists()
        click("Edit rules and DNS")
        click("DNS")
        click("Add DNS host")
        ui.onNodeWithText("Hostname").performScrollTo().performTextInput("fixture.test")
        ui.onNodeWithText("IPv4 or IPv6 address").performScrollTo().performTextInput("192.0.2.81")
        ui.activityRule.scenario.recreate()
        ui.onNodeWithText("Hostname").performScrollTo().assertTextContains("fixture.test")
        ui.onNodeWithText("IPv4 or IPv6 address").performScrollTo().assertTextContains("192.0.2.81")
        assertFalse(snapshot().route(id).mapObject("profile").mapObject("DnsHosts").has("fixture.test"))
        click("Save changes")
        ui.waitUntil(5000) { snapshot().route(id).mapObject("profile").mapObject("DnsHosts").string("fixture.test") == "192.0.2.81" }
        click("Duplicate")
        ui.waitUntil(5000) { snapshot().routes.size == 2 }
        val copy = snapshot().routes.single { it.string("id") != id }
        assertEquals("Editor fixture copy", copy.string("name"))
        assertEquals("192.0.2.81", copy.mapObject("profile").mapObject("DnsHosts").string("fixture.test"))
        assertEquals(id, snapshot().assignments.getString(snapshot().sources.single().getString("id")))
    }

    @Test fun rawRoutingSaveUsesVisibleTextAndRefreshesForm() {
        ui.onNode(hasText("Routing") and hasClickAction()).performClick()
        click("New profile")
        click("Advanced")
        ui.onNodeWithText("Profile name").performTextReplacement("JSON fixture")
        click("Save changes")
        ui.waitUntil(5000) { snapshot().routes.isNotEmpty() }
        click("JSON fixture"); click("Edit JSON")
        val jsonField = ui.onNode(hasText("Routing JSON") and hasSetTextAction())
        val defaults = JSONObject(jsonField.fetchSemanticsNode().config[androidx.compose.ui.semantics.SemanticsProperties.EditableText].text)
        assertEquals("block-direct-proxy", defaults.string("RouteOrder"))
        assertEquals("AsIs", defaults.string("DomainStrategy"))
        assertEquals("1.1.1.1", defaults.string("DomesticDNSIP"))
        val profile = obj("Name" to "JSON fixture", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8", "DirectSites" to JSONArray(listOf("domain:example.test")))
        profile.put("Name", "Saved raw fixture")
        jsonField.performTextReplacement(profile.toString())
        click("Save changes")
        ui.waitUntil(5000) { snapshot().routes.singleOrNull()?.string("name") == "Saved raw fixture" }
        click("Edit rules and DNS")
        ui.onAllNodesWithText("Domains").onFirst().performScrollTo().assertTextContains("domain:example.test")
        click("Advanced")
        ui.onNodeWithText("Profile name").assertTextContains("Saved raw fixture")
    }

    @Test fun controlLinksAndDiagnosticScreens() {
        val launch = Intent(ui.activity.intent)
        fun send(value: String) { ui.runOnUiThread { ui.activity.startActivity(Intent(ui.activity, MainActivity::class.java).setAction(Intent.ACTION_VIEW).setData(Uri.parse(value))) } }
        send("elarni://status")
        ui.waitUntil(5000) { ui.activity.intent.dataString == "elarni://status" }
        ui.waitUntil(5000) { ui.onAllNodesWithText("Connection: disconnected").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithText("Connection: disconnected").assertExists()
        ui.onNodeWithContentDescription("Dismiss").performClick()
        assertNull(ui.activity.interaction.incoming)
        // The snackbar relaunches only when its notice key changes; let the UI see the dismissal first.
        ui.waitUntil(5000) { ui.activity.interaction.notice == null && ui.onAllNodesWithText("Connection: disconnected").fetchSemanticsNodes().isEmpty() }
        val primary = Intent(Intent.ACTION_VIEW, Uri.parse("elarni://status")).addCategory(Intent.CATEGORY_BROWSABLE)
        assertTrue(ui.activity.packageManager.queryIntentActivities(primary, 0).any { it.activityInfo.packageName == ui.activity.packageName })
        send("elarni://status")
        ui.waitUntil(5000) { ui.activity.intent.dataString == "elarni://status" }
        ui.waitUntil(5000) { ui.onAllNodesWithText("Connection: disconnected").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithContentDescription("Dismiss").performClick()
        assertNull(ui.activity.interaction.incoming)
        send("happ://close/")
        ui.waitUntil(5000) { ui.activity.intent.dataString == "happ://close/" }
        assertNull(ui.activity.interaction.incoming)
        // Links ask before stopping or importing; Cancel leaves everything alone.
        ui.waitUntil(5000) { ui.onAllNodesWithText("A link asks Elarni to disconnect.").fetchSemanticsNodes().isNotEmpty() }
        ui.onNode(hasText("Cancel") and hasAnyAncestor(isDialog())).performClick()
        assertFalse(ui.activity.interaction.linkStop)
        send("elarni://connect?unexpected=1")
        ui.waitUntil(5000) { ui.onAllNodesWithText("A link wants to add profiles to Elarni.").fetchSemanticsNodes().isNotEmpty() }
        assertNull(ui.activity.interaction.incoming)
        ui.onNode(hasText("Import") and hasAnyAncestor(isDialog())).performClick()
        ui.waitUntil(5000) { repo.state.value.error != null }
        assertTrue(snapshot().nodes.isEmpty())
        ui.onNodeWithText("Link or configuration").assertDoesNotExist()
        ui.onNodeWithContentDescription("Dismiss").performClick()
        ui.runOnUiThread { ui.activity.intent = launch }
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("System info")
        ui.waitUntil(5000) { !repo.state.value.busy }
        ui.onNodeWithText("Elarni").assertExists()
        ui.onNodeWithText(BuildConfig.VERSION_NAME).assertExists()
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        click("Route table")
        ui.waitUntil(5000) { !repo.state.value.busy }
        val network = call("routeTable").objects("networks").first()
        ui.onNodeWithText("${network.string("interface")} · ${if (network.optBoolean("vpn")) "VPN" else "Physical network"}").assertExists()
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        click("Backup and repair"); click("Troubleshooting")
        click("Reset connection")
        ui.waitUntil(5000) { !repo.state.value.busy }
        assertEquals("disconnected", repo.state.value.connection)
        ui.onAllNodesWithContentDescription("Dismiss").fetchSemanticsNodes().takeIf { it.isNotEmpty() }?.let { ui.onNodeWithContentDescription("Dismiss").performClick() }
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        ui.onNodeWithText("Create encrypted backup").assertExists()
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        click("General")
        click("Open-source notices")
        ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Copyright 2026 Elarni contributors", substring = true))
        click("Android components")
        ui.waitUntil(5000) { ui.onAllNodesWithText("Android runtime components", substring = true).fetchSemanticsNodes().isNotEmpty() }
        val notices = ui.activity.assets.open("OPEN_SOURCE_NOTICES").bufferedReader().use { it.readText() }
        assertTrue(notices.contains("Stephen Colebourne & Michael Nascimento Santos"))
        assertTrue(notices.contains("Boost Software License - Version 1.0"))
    }

    // The core runs in this process: the screen shows its redacted lines at the saved level and shares them as a file.
    @Test fun coreLogFollowsTheChosenLevelAndShares() {
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Backup and repair"); click("Logs")
        click("Level"); click("Debug")
        ui.waitUntil(5000) { snapshot().settings.getString("logLevel") == "debug" && Native.call("readLogs").getString("level") == "debug" }
        assertFalse("The running core does not read the log level", Settings.runtime(snapshot().settings).has("logLevel"))
        val before = Native.call("readLogs").getLong("last")
        Native.call("runXrayFromJson", obj("configJSON" to obj("outbounds" to JSONArray(listOf(obj("protocol" to "freedom")))).toString()))
        try {
            ui.waitUntil(5000) { Native.call("readLogs", obj("after" to before)).objects("entries").any { it.string("text").endsWith(" started") } }
        } finally { Native.call("stopXray") }
        val shared = java.io.File(ui.activity.cacheDir, "shared/elarni-log.txt").apply { delete() }
        ui.waitUntil(5000) { ui.onAllNodesWithText(" started", substring = true).fetchSemanticsNodes().isNotEmpty() }
        click("Share")
        ui.waitUntil(5000) { shared.exists() }
        val text = shared.readText()
        assertTrue(text, text.startsWith("Elarni log, level debug\n") && text.lines().any { it.endsWith(" started") })
        // The file is written before the chooser opens; Back must reach the chooser, not this screen.
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        ui.waitUntil(10_000) { automation.rootInActiveWindow?.packageName.let { it != null && it != ui.activity.packageName } }
        automation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
        ui.waitUntil(10_000) { automation.rootInActiveWindow?.packageName == ui.activity.packageName && ui.activity.hasWindowFocus() }
        click("Level"); click("Off")
        ui.waitUntil(5000) { Native.call("readLogs").getString("level") == "none" }
        assertEquals("none", snapshot().settings.getString("logLevel"))
    }

    // The feed is the user's: off by default in debug builds (release builds read Elarni's releases) and https only. Its notice installs nothing, and Not now hides that version.
    @Test fun updateNoticeFollowsTheFeedTheUserSets() {
        // A GitHub reply's own url is its API address; the notice links to html_url.
        assertEquals("0.4.1" to "https://github.com/o/elarni/releases/tag/v0.4.1", UpdateCheck.parse(
            """{"url":"https://api.github.com/repos/o/elarni/releases/1","tag_name":"v0.4.1","html_url":"https://github.com/o/elarni/releases/tag/v0.4.1"}"""))
        assertNull(UpdateCheck.parse("""{"version":"0.4.0","url":"http://mirror.example/"}"""))
        assertEquals(0, UpdateCheck.compare("0.3.6", "0.3.6+9")); assertNull(UpdateCheck.compare("0.4.0-beta", "0.3.6"))
        assertTrue(UpdateCheck.compare("0.3.10", "0.3.9")!! > 0)
        val fetched = java.util.concurrent.CopyOnWriteArrayList<String>()
        val network = UpdateCheck.fetch
        // The real fetch reaches the fetcher, which asks about a loopback feed instead of reading it; an unprepared call failed before that.
        val reply = runCatching { network("https://127.0.0.1:9/feed.json") }.exceptionOrNull()
        assertTrue("$reply", reply is org.json.JSONException)
        UpdateCheck.fetch = { url -> fetched.add(url); """{"version":"999.0.0","url":"https://mirror.example/elarni/"}""" }
        val prefs = ui.activity.getSharedPreferences("ui", android.content.Context.MODE_PRIVATE)
        prefs.edit().remove("dismissedUpdate").commit()
        try {
            ui.waitForIdle()
            assertTrue(fetched.isEmpty())
            ui.onNode(hasText("Settings") and hasClickAction()).performClick()
            click("General")
            editSetting("Update feed", "http://mirror.example/feed.json")
            click("Save changes")
            ui.waitUntil(5000) { ui.onAllNodesWithText("Use an https:// address for the update feed, or leave it empty.").fetchSemanticsNodes().isNotEmpty() }
            assertEquals("", snapshot().settings.getString("updateFeedURL"))
            // The error stays until dismissed and covers Save changes.
            ui.onNodeWithContentDescription("Dismiss").performClick()
            editSetting("Update feed", "https://mirror.example/feed.json")
            click("Save changes")
            ui.waitUntil(5000) { snapshot().settings.getString("updateFeedURL") == "https://mirror.example/feed.json" }
            assertFalse("The running core does not read the feed", Settings.runtime(snapshot().settings).has("updateFeedURL"))
            ui.onNode(hasText("Home") and hasClickAction()).performClick()
            ui.waitUntil(5000) { ui.onAllNodesWithText("Elarni 999.0.0 is available").fetchSemanticsNodes().isNotEmpty() }
            assertEquals(listOf("https://mirror.example/feed.json"), fetched.toList())
            ui.onNodeWithText("You have ${BuildConfig.VERSION_NAME}", substring = true).assertExists()
            ui.onNode(hasText("Download") and hasClickAction()).assertExists()
            click("Not now")
            ui.onNodeWithText("Elarni 999.0.0 is available").assertDoesNotExist()
            assertEquals("999.0.0", prefs.getString("dismissedUpdate", ""))
            // A new activity keeps that version hidden and does not read the feed again within the day.
            ui.activityRule.scenario.recreate()
            ui.waitForIdle()
            ui.onNodeWithText("Elarni 999.0.0 is available").assertDoesNotExist()
            assertEquals(1, fetched.size)
        } finally { UpdateCheck.fetch = network }
    }

    // Elarni ships no servers, so an empty Home says where one comes from and adds it from there.
    @Test fun emptyHomeWalksThroughTheFirstServer() {
        val steps = hasText("Get connected in three steps")
        ui.onNode(hasScrollToIndexAction()).performScrollToNode(steps)
        ui.onNodeWithText("Elarni has no servers of its own", substring = true).assertExists()
        ui.onNodeWithText("Android asks once to allow the VPN connection", substring = true).assertExists()
        call("settings", obj("settings" to obj("xrayTunEnabled" to false)))
        ui.onNodeWithText("turn on System VPN in Settings > Connection", substring = true).assertExists()
        ui.onNode(hasText("Open file") and hasClickAction()).assertExists()
        click("Scan QR code")
        ui.onNodeWithText("Scan a connection QR code").assertExists()
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        ui.runOnIdle { ui.activity.copy("vless://00000000-0000-4000-8000-000000000001@127.0.0.1:18080?encryption=none#Onboarding%20fixture") }
        click("Paste link")
        ui.waitUntil(10_000) { snapshot().nodes.size == 1 }
        ui.onNode(steps).assertDoesNotExist()
    }

    // The QR screen reads the live camera through the photo decoder, and lets the camera go when it closes.
    @Test fun liveScannerReadsCameraFramesAndImports() {
        val link = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:18080?encryption=none#Live%20QR"
        val png = android.util.Base64.decode(Native.call("clientQR", obj("text" to link)).getString("png"), android.util.Base64.DEFAULT)
        val code = android.graphics.BitmapFactory.decodeByteArray(png, 0, png.size)
        // A camera frame's luminance plane: rows padded past the width, the code off-center on a gray scene.
        val width = 640; val height = 480; val stride = 704
        fun plane() = ByteArray(stride * (height - 1) + width) { 90 }
        val frame = plane()
        for (y in 0 until code.height) for (x in 0 until code.width)
            frame[(y + 60) * stride + x + 200] = (if (android.graphics.Color.red(code.getPixel(x, y)) > 127) 230 else 20).toByte()
        assertEquals(link, QRFrames.decode(java.nio.ByteBuffer.wrap(frame), stride, width, height))
        assertNull(QRFrames.decode(java.nio.ByteBuffer.wrap(plane()), stride, width, height))
        // The emulated camera shows no code, so the decoder stands in once the screen has been checked.
        val sizes = java.util.concurrent.CopyOnWriteArrayList<Pair<Int, Int>>()
        val accept = java.util.concurrent.atomic.AtomicBoolean(false)
        val decoder = QRFrames.read
        QRFrames.read = { _, _, w, h -> sizes.add(w to h); if (accept.get()) link else null }
        val cameras = ui.activity.getSystemService(android.hardware.camera2.CameraManager::class.java)
        val busy = java.util.concurrent.ConcurrentHashMap.newKeySet<String>()
        val opened = java.util.concurrent.atomic.AtomicBoolean(false)
        val availability = object : android.hardware.camera2.CameraManager.AvailabilityCallback() {
            override fun onCameraAvailable(id: String) { busy.remove(id) }
            override fun onCameraUnavailable(id: String) { busy.add(id); opened.set(true) }
        }
        cameras.registerAvailabilityCallback(availability, android.os.Handler(android.os.Looper.getMainLooper()))
        try {
            ui.waitForIdle()
            assertTrue("No camera is open before the screen", busy.isEmpty())
            ui.onNodeWithContentDescription("Import profiles").performClick()
            ui.onNode(hasText("Scan QR code") and hasAnyAncestor(isPopup())).performClick()
            ui.waitUntil(15_000) { sizes.size >= 3 }
            assertTrue(sizes.all { (w, h) -> w in 1..1280 && h in 1..960 })
            assertTrue(opened.get())
            ui.onNodeWithContentDescription("Camera preview").assertExists()
            ui.onNodeWithText("Photograph QR").assertExists()
            ui.onNodeWithContentDescription("Choose QR image").assertExists()
            accept.set(true)
            ui.waitUntil(10_000) { snapshot().nodes.size == 1 }
            assertEquals("Live QR", snapshot().nodes.single().string("name"))
            ui.onNodeWithText("Scan a connection QR code").assertDoesNotExist()
            ui.waitUntil(5000) { busy.isEmpty() }
        } finally {
            QRFrames.read = decoder
            cameras.unregisterAvailabilityCallback(availability)
        }
    }

    @Test fun nativeDocumentImportExportAndDraftRotation() {
        val link = "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:18080?encryption=none#Document%20fixture"
        ui.runOnIdle { ui.activity.copy("") }
        ui.onNodeWithContentDescription("Import profiles").performClick()
        click("Import from clipboard")
        ui.waitUntil(5000) { ui.onAllNodesWithText("The clipboard is empty. Copy a link or configuration first.").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithText("The clipboard is empty. Copy a link or configuration first.").assertExists()
        ui.onNodeWithContentDescription("Dismiss").performClick()
        ui.runOnIdle { ui.activity.copy(link) }
        ui.onNodeWithContentDescription("Import profiles").performClick()
        click("Import from clipboard")
        ui.waitUntil(10_000) { snapshot().nodes.size == 1 }
        ui.onNodeWithText("Link or configuration").assertDoesNotExist()
        ui.activityRule.scenario.recreate()
        assertEquals("Document fixture", snapshot().nodes.single().string("name"))
        // Another server: a local import skips a server it already has, whatever its name.
        val fileLink = link.replace(":18080?", ":18081?").replace("Document%20fixture", "File%20fixture")
        val name = "elarni-${newId().take(12)}.txt"
        // Create the fixture through the actual document provider. Android 11's
        // Downloads provider does not expose an arbitrary MediaStore insertion in
        // the same way as newer Android releases.
        ui.runOnIdle { ui.activity.save(fileLink, name) }
        systemClick("Save")
        ui.waitUntil(10_000) { ui.activity.interaction.notice == "File saved." }
        ui.onNodeWithContentDescription("Dismiss").performClick()
        ui.onNodeWithContentDescription("Import profiles").performClick()
        click("Import file")
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        ui.waitUntil(5000) { automation.rootInActiveWindow?.packageName?.toString()?.contains("documentsui") == true }
        // The picker shows its window before its list; give the list time before looking elsewhere.
        val listed = runCatching {
            ui.waitUntil(5000) { !automation.rootInActiveWindow?.findAccessibilityNodeInfosByText(name).isNullOrEmpty() }
        }.isSuccess
        if (!listed) {
            systemClick("Show roots")
            systemClick("Downloads")
        }
        systemClick(name)
        ui.waitUntil(10_000) { snapshot().nodes.any { it.string("name") == "File fixture" } }
        ui.onNodeWithText("Link or configuration").assertDoesNotExist()
        val share = call("share", obj("id" to snapshot().nodes.first().getString("id"))).getString("text")
        ui.runOnIdle { ui.activity.save(share, "elarni-export-${newId().take(12)}.txt") }
        systemClick("Save")
        ui.waitUntil(10_000) { ui.activity.interaction.notice == "File saved." }
    }

    @Test fun countryGroupsAndServerFilters() {
        val names = listOf("[DE] Frankfurt", "Германия Berlin", "🇳🇱 Amsterdam", "France via Germany", "Stay in touch", "🇪🇺 Europe")
        val links = names.mapIndexed { index, name -> "socks://127.0.0.1:${18100 + index}#${java.net.URLEncoder.encode(name, "UTF-8").replace("+", "%20")}" }
        call("import", obj("text" to links.joinToString("\n")))
        val german = snapshot().nodes.first { it.string("name") == "[DE] Frankfurt" }
        call("favorite", obj("id" to german.getString("id"), "value" to true))
        call("select", obj("id" to snapshot().nodes.first { it.string("name") == "🇳🇱 Amsterdam" }.string("id")))
        val list = ui.onNode(hasScrollToIndexAction())
        list.performScrollToNode(hasText("Germany"))
        click("Germany")
        list.performScrollToNode(hasText("[DE] Frankfurt"))
        ui.onNodeWithText("[DE] Frankfurt").assertExists()
        list.performScrollToNode(hasText("Германия Berlin"))
        ui.onNodeWithText("Германия Berlin").assertExists()
        list.performScrollToNode(hasText("European Union"))
        click("European Union")
        list.performScrollToNode(hasText("Europe"))
        ui.onNodeWithText("Europe").assertExists()
        list.performScrollToNode(hasText("Other locations"))
        list.performScrollToNode(hasText("France via Germany"))
        ui.onNodeWithText("France via Germany").assertExists()
        list.performScrollToNode(hasText("Stay in touch"))
        ui.onNodeWithText("Stay in touch").assertExists()
        list.performScrollToNode(hasText("Search servers"))
        ui.onNodeWithText("Search servers").performTextInput("Netherlands")
        // The keyboard opens after the input and its inset animation, which the test cannot wait for, shrinks the list
        // under a row scrolled to the bottom edge: scroll again until the row stays shown.
        ui.waitUntil(5000) {
            list.performScrollToNode(hasText("Amsterdam"))
            ui.onAllNodesWithText("Amsterdam").fetchSemanticsNodes().isNotEmpty()
        }
        list.performScrollToNode(hasText("Search servers"))
        ui.onNodeWithText("Search servers").performTextClearance()
        click("Favorites")
        list.performScrollToNode(hasText("[DE] Frankfurt"))
        ui.onNodeWithText("[DE] Frankfurt").assertExists()
        ui.onNodeWithText("Other locations").assertDoesNotExist()
        click("Recent")
        ui.onNodeWithText("No servers match this filter.").assertExists()
    }

    @Test fun localProxyLoginShowsCopiesAndNeedsAWarningToDrop() {
        call("credentials", obj("username" to "proxyuser", "password" to "synthetic proxy password"))
        call("settings", obj("settings" to obj("xrayTunEnabled" to false, "inboundAuthEnabled" to true)))
        val prefs = ui.activity.getSharedPreferences("ui", android.content.Context.MODE_PRIVATE)
        prefs.edit().remove("loginWarningDismissed").commit()
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Connection")
        // Settings shows the login that apps sign in with.
        ui.onNode(hasText("proxyuser · ••••••••••••")).performScrollTo()
        click("Show")
        ui.onNodeWithText("proxyuser · synthetic proxy password").assertExists()
        click("Copy")
        ui.runOnIdle {
            val clip = ui.activity.getSystemService(android.content.ClipboardManager::class.java).primaryClip!!
            assertEquals("synthetic proxy password", clip.getItemAt(0).text.toString())
            assertTrue(clip.description.extras!!.getBoolean("android.content.extra.IS_SENSITIVE"))
        }
        // Dropping the login needs a warning.
        click("Allow apps without a login")
        ui.onNodeWithText("Allow apps without a login?").assertExists()
        ui.onNode(hasText("Cancel") and hasAnyAncestor(isDialog())).performClick()
        ui.onNode(hasText("Allow apps without a login") and hasClickAction()).assertIsOff()
        click("Allow apps without a login")
        click("Allow without login")
        click("Save changes")
        ui.waitUntil(5000) { !snapshot().settings.getBoolean("inboundAuthEnabled") }
        // Home warns, and can require the login again or wait.
        ui.onNode(hasText("Home") and hasClickAction()).performClick()
        val warning = "Your local proxy accepts apps without a login"
        ui.waitUntil(5000) { ui.onAllNodesWithText(warning).fetchSemanticsNodes().isNotEmpty() }
        click("Require a login")
        ui.waitUntil(5000) { snapshot().settings.getBoolean("inboundAuthEnabled") }
        ui.waitUntil(5000) { ui.onAllNodesWithText(warning).fetchSemanticsNodes().isEmpty() }
        call("settings", obj("settings" to obj("inboundAuthEnabled" to false)))
        ui.waitUntil(5000) { ui.onAllNodesWithText(warning).fetchSemanticsNodes().isNotEmpty() }
        click("Not now")
        ui.onNodeWithText(warning).assertDoesNotExist()
        ui.activityRule.scenario.recreate()
        ui.waitForIdle()
        ui.onNodeWithText(warning).assertDoesNotExist()
        assertTrue(prefs.getBoolean("loginWarningDismissed", false))
    }
    @Test fun blockTrafficWithoutVpnOpensAndroidVpnSettings() {
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Connection")
        // Android owns the block; the row says so and opens its settings.
        ui.onNode(hasText("Android manages this: turn on Always-on VPN and Block connections without VPN.")).performScrollTo()
        click("Open")
        val automation = InstrumentationRegistry.getInstrumentation().uiAutomation
        ui.waitUntil(10_000) { automation.rootInActiveWindow?.packageName == "com.android.settings" }
        automation.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
        ui.waitUntil(10_000) { automation.rootInActiveWindow?.packageName == ui.activity.packageName }
    }
    @Test fun settingsCategoriesAndVisibleServerTestsMatchIOS() {
        java.net.ServerSocket(0, 4, java.net.InetAddress.getByName("127.0.0.1")).use { endpoint ->
            call("import", obj("text" to "socks://127.0.0.1:${endpoint.localPort}#Germany%20Visible\nsocks://127.0.0.1:1#Netherlands%20Hidden"))
            ui.onNode(hasText("Settings") and hasClickAction()).performClick()
            val categories = listOf("General", "Appearance", "Connection", "DNS", "Apps & routes", "Advanced", "Server tests", "Backup and repair", "System info", "Route table")
            categories.forEach { title ->
                click(title)
                ui.onNodeWithContentDescription("Back").assertExists()
                ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
            }
            click("Connection")
            editSetting("SOCKS port", "12345")
            click("Proxy login")
            ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
            ui.onNodeWithText("SOCKS port").assertTextContains("12345")
            ui.activityRule.scenario.recreate()
            ui.onNodeWithText("SOCKS port").assertTextContains("12345")
            click("Cancel")
            assertEquals(10890, snapshot().settings.getInt("socksPort"))
            click("Server tests")
            click("Proxy"); click("Direct TCP")
            editSetting("Timeout in seconds · 1–15", "7")
            click("Save changes")
            ui.waitUntil(5000) { snapshot().settings.optInt("probeTimeout") == 7 }
            ui.onNodeWithContentDescription("Back").assertExists()
            ui.activityRule.scenario.recreate()
            ui.onNodeWithText("Timeout in seconds · 1–15").assertTextContains("7")
            editSetting("Timeout in seconds · 1–15", "0")
            click("Save changes")
            ui.waitUntil(5000) { repo.state.value.error == "invalid_settings" }
            assertEquals(7, snapshot().settings.getInt("probeTimeout"))
            ui.onNodeWithContentDescription("Dismiss").performClick()
            ui.activityRule.scenario.recreate()
            ui.onNodeWithContentDescription("Dismiss").assertDoesNotExist()
            click("Open server list")
            ui.onNodeWithContentDescription("Server options").performClick()
            ui.onNode(hasText("Germany") and hasAnyAncestor(isPopup())).performClick()
            ui.onNodeWithContentDescription("Test visible servers").performClick()
            val visible = snapshot().nodes.single { it.string("name") == "Germany Visible" }.string("id")
            val hidden = snapshot().nodes.single { it.string("name") == "Netherlands Hidden" }.string("id")
            ui.waitUntil(10_000) { repo.state.value.pings[visible]?.string("status") == "success" }
            assertEquals("tcp", repo.state.value.pings.getValue(visible).string("protocol"))
            assertFalse(repo.state.value.pings.containsKey(hidden))
            ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Germany"))
            ui.onNodeWithTag("country-ping-DE", useUnmergedTree = true).assertExists()
            ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription("Server actions"))
            ui.onNodeWithContentDescription("Server actions").performClick()
            ui.onNode(hasText("Favorite") and hasAnyAncestor(isPopup())).performClick()
            ui.waitUntil(5000) { snapshot().node(visible).optBoolean("favorite") }
            val group = snapshot().sourceFor(visible).string("id")
            call("automation", obj("configuration" to Automation.defaults().put("enabled", true).put("policy", "orderedFallback")
                .put("subscriptionID", group).put("nodeIDs", JSONArray(listOf(visible, hidden)))
                .put("targets", JSONArray(listOf(obj("id" to "ui-health", "url" to "http://127.0.0.1:${endpoint.localPort}/health", "expectedStatus" to 200, "expectedBody" to ""))))))
            ui.onNodeWithContentDescription("Server actions").performClick()
            ui.onNodeWithText("Details").performClick()
            click(if (snapshot().selected == visible) "Selected server" else "Use server")
            ui.onNodeWithText("Search servers").assertExists()
            assertEquals(visible, snapshot().selected)
            val recovery = snapshot().data.mapObject("automation")
            // The picked server becomes the primary; the allowed backups stay.
            assertTrue(recovery.optBoolean("enabled"))
            assertEquals("orderedFallback", recovery.string("policy"))
            assertEquals(group, recovery.string("subscriptionID"))
            assertEquals(listOf(visible, hidden), recovery.strings("nodeIDs"))
            click("All locations")
            ui.onNodeWithContentDescription("Server options").performClick()
            click("Alphabetical")
            ui.waitUntil(5000) { snapshot().settings.string("sort") == "alphabet" }
            assertEquals("success", repo.state.value.pings.getValue(visible).string("status"))
            assertFalse(repo.state.value.pings.containsKey(hidden))
            try {
                call("ping", Settings.probeArgs(snapshot().settings, listOf(visible)).put("sourceId", "missing-source"))
                fail("A probe must not escape its subscription scope")
            } catch (_: AppFailure) { }
            capture("home-country-options")
        }
    }

    @Test fun manualProbesRunTogetherAndPublishCountryAndRowBadges() {
        val pool = java.util.concurrent.Executors.newCachedThreadPool()
        val ready = java.util.concurrent.CountDownLatch(26)
        val sequence = java.util.concurrent.atomic.AtomicInteger()
        val stalled = java.util.concurrent.CountDownLatch(26)
        java.net.ServerSocket(0, 64, java.net.InetAddress.getByName("127.0.0.1")).use { origin ->
            pool.execute {
                while (!origin.isClosed) {
                    val peer = runCatching { origin.accept() }.getOrNull() ?: break
                    pool.submit respond@{
                        peer.use {
                            it.soTimeout = 5000
                            val input = it.getInputStream().bufferedReader()
                            val request = input.readLine().orEmpty()
                            while (!input.readLine().isNullOrEmpty()) { }
                            if (request.contains("/stall")) {
                                stalled.countDown()
                                it.getInputStream().read()
                                return@respond
                            }
                            val index = sequence.getAndIncrement()
                            ready.countDown()
                            if (!ready.await(4, java.util.concurrent.TimeUnit.SECONDS)) return@respond
                            Thread.sleep(if (index == 25) 1000 else 200)
                            it.getOutputStream().write("HTTP/1.1 200 OK\r\nContent-Length: 8\r\nConnection: close\r\n\r\nelarniOK".toByteArray())
                        }
                    }
                }
            }
            // One upstream port per server: a local import skips a server it already has, whatever its name.
            val reserved = List(26) { java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")) }
            val upstreams = reserved.map { it.localPort }.also { reserved.forEach(java.net.ServerSocket::close) }
            Native.call("runXrayFromJson", obj("configJSON" to obj("log" to obj("loglevel" to "none"),
                "inbounds" to JSONArray(upstreams.map { obj("listen" to "127.0.0.1", "port" to it, "protocol" to "socks", "settings" to obj("auth" to "noauth")) }),
                "outbounds" to JSONArray(listOf(obj("protocol" to "freedom")))).toString()))
            try {
                call("import", obj("text" to upstreams.withIndex().joinToString("\n") { (index, port) -> "socks://127.0.0.1:$port#Germany%20Parallel%20$index" }))
                call("settings", obj("settings" to obj("probeMode" to "proxy", "probeURL" to "http://127.0.0.1:${origin.localPort}/parallel",
                    "probeExpectedStatus" to 200, "probeExpectedBody" to "elarniOK")))
                val started = System.nanoTime()
                ui.onNodeWithContentDescription("Test visible servers").performClick()
                try { ui.waitUntil(3000) { repo.state.value.pings.size == 25 } }
                catch (error: Throwable) {
                    throw AssertionError("Parallel arrivals=${sequence.get()}, nodes=${repo.state.value.catalog.objects("subscriptions").sumOf { it.objects("nodes").size }}, busy=${repo.state.value.busy}, results=${repo.state.value.pings.values.map { it.string("status") to it.string("error") }}", error)
                }
                assertTrue(repo.state.value.busy)
                ui.onNode(hasScrollToIndexAction(), useUnmergedTree = true).performScrollToNode(hasTestTag("country-ping-DE"))
                ui.onNodeWithTag("country-ping-DE", useUnmergedTree = true).assertExists()
                ui.waitUntil(5000) { !repo.state.value.busy }
                val elapsed = (System.nanoTime() - started) / 1_000_000
                println("Android 26 manual proxy probes: $elapsed ms")
                assertEquals(26, sequence.get())
                assertEquals(26, repo.state.value.pings.size)
                assertTrue(repo.state.value.pings.values.all { it.string("status") == "success" })
                assertTrue("26 probes should complete in one delayed response round: $elapsed ms", elapsed < 3500)
                val selected = snapshot().selected
                ui.onNode(hasScrollToIndexAction(), useUnmergedTree = true).performScrollToNode(hasTestTag("server-ping-$selected"))
                ui.onNodeWithTag("server-ping-$selected", useUnmergedTree = true).assertExists()
                capture("parallel-ping-light")
                call("settings", obj("settings" to obj("theme" to "dark")))
                capture("parallel-ping-dark")
                call("settings", obj("settings" to obj("probeURL" to "http://127.0.0.1:${origin.localPort}/stall")))
                val completed = repo.state.value.pings.mapValues { it.value.toString() }
                ui.runOnUiThread { ui.activity.testServers(snapshot().nodes.map { it.string("id") }) }
                assertTrue("All stalled probes must start together", stalled.await(3, java.util.concurrent.TimeUnit.SECONDS))
                val cancelledAt = System.nanoTime()
                repo.cancel()
                ui.waitUntil(2000) { !repo.state.value.busy }
                assertTrue((System.nanoTime() - cancelledAt) / 1_000_000 < 2000)
                assertEquals(completed, repo.state.value.pings.mapValues { it.value.toString() })
            } finally { Native.call("stopXray"); pool.shutdownNow() }
        }
    }

    @Test fun perAppIconsSelectionPagingAndPinnedSave() {
        val apps = call("apps").objects("apps")
        assertTrue("The emulator must expose enough real apps to exercise paging", apps.size > 16)
        val selected = apps.last()
        val available = apps.dropLast(1)
        call("settings", obj("settings" to obj("perAppProcesses" to JSONArray(listOf(selected.string("package"))))))
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Apps & routes")
        ui.onNode(hasText("Per-app routing") and hasClickAction()).assertHeightIsAtLeast(56.dp).assertWidthIsAtLeast(240.dp)
        click("Per-app routing")
        val list = ui.onNodeWithTag("per-app-list")
        ui.waitUntil(10_000) { ui.onAllNodesWithText("Selected apps · 1").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithText("Save changes").assertIsDisplayed()
        list.performScrollToNode(hasTestTag("per-app-${selected.string("package")}"))
        ui.onNodeWithContentDescription("${selected.string("name")} icon").assertExists()
        list.performScrollToNode(hasText("Showing 8 of ${available.size} apps"))
        ui.onNodeWithText("Save changes").assertIsDisplayed()
        capture("per-app-initial")
        click("Show more")
        list.performScrollToNode(hasText("Showing 16 of ${available.size} apps"))
        ui.onNodeWithText("Save changes").assertIsDisplayed()
        capture("per-app-more")
        list.performScrollToNode(hasText("Search installed apps"))
        val next = available.last()
        ui.onNodeWithText("Search installed apps").performTextReplacement(next.string("package"))
        dismissKeyboard()
        list.performScrollToNode(hasTestTag("per-app-${selected.string("package")}"))
        ui.onNodeWithTag("per-app-${selected.string("package")}").assertIsDisplayed()
        list.performScrollToNode(hasTestTag("per-app-${next.string("package")}"))
        ui.onNodeWithTag("per-app-${next.string("package")}").performClick()
        list.performScrollToNode(hasText("Selected apps · 2"))
        list.performScrollToNode(hasText("Search installed apps"))
        ui.onNodeWithText("Search installed apps").performTextClearance()
        ui.activityRule.scenario.recreate()
        ui.onNodeWithText("Save changes").assertIsDisplayed()
        // The recreated editor lists the draft only after it reloads the installed apps.
        ui.waitUntil(10_000) { runCatching { list.performScrollToNode(hasText("Selected apps · 2")) }.isSuccess }
        capture("per-app-selected")
        click("Off"); click("Only listed apps")
        click("Save changes")
        ui.waitUntil(10_000) { snapshot().settings.string("perAppMode") == "proxyOnly" }
        assertEquals(setOf(selected.string("package"), next.string("package")), snapshot().settings.strings("perAppProcesses").toSet())
        click("Per-app routing")
        click("Only listed apps"); click("Off"); click("Cancel")
        assertEquals("proxyOnly", snapshot().settings.string("perAppMode"))
    }

    // A listed package that is not installed matched nothing and was hidden; it is listed so it can be removed.
    @Test fun perAppListsSavedPackagesThatAreNotInstalled() {
        val installed = call("apps").objects("apps").first().string("package")
        val missing = "com.example.elarni.notinstalled"
        call("settings", obj("settings" to obj("perAppMode" to "bypass", "perAppProcesses" to JSONArray(listOf(installed, missing)), "xrayTunEnabled" to true)))
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Apps & routes")
        click("Per-app routing")
        val list = ui.onNodeWithTag("per-app-list")
        ui.waitUntil(10_000) { ui.onAllNodesWithText("Selected apps · 2").fetchSemanticsNodes().isNotEmpty() }
        list.performScrollToNode(hasTestTag("per-app-missing-$missing"))
        ui.onNodeWithText("Not installed on this device, so this rule matches nothing.").assertIsDisplayed()
        ui.onNodeWithTag("per-app-missing-$missing").performClick()
        ui.waitUntil(10_000) { ui.onAllNodesWithText("Selected apps · 1").fetchSemanticsNodes().isNotEmpty() }
        click("Save changes")
        ui.waitUntil(10_000) { snapshot().settings.strings("perAppProcesses") == listOf(installed) }
    }

    // The list reads this process's core; without the VPN its lookup names no owner ("-1").
    @Test fun perAppConnectionsListTheCoresRecentConnections() {
        call("settings", obj("settings" to obj("perAppMode" to "bypass", "perAppProcesses" to JSONArray(listOf(call("apps").objects("apps").first().string("package"))), "xrayTunEnabled" to true)))
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Apps & routes")
        click("Per-app routing")
        ui.onNodeWithTag("per-app-connections").performScrollTo().performClick()
        ui.waitUntil(10_000) { ui.onAllNodesWithTag("per-app-connections-disconnected").fetchSemanticsNodes().isNotEmpty() }
        ui.onNodeWithTag("per-app-connections-done").performClick()
        java.net.ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1")).use { echo ->
            kotlin.concurrent.thread { runCatching { echo.accept().use { it.getOutputStream().write(it.getInputStream().read()) } } }
            val inbound = java.net.ServerSocket(0, 50, java.net.InetAddress.getByName("127.0.0.1")).use { it.localPort }
            val config = obj(
                "inbounds" to JSONArray(listOf(obj("tag" to "elarni-tun", "listen" to "127.0.0.1", "port" to inbound, "protocol" to "dokodemo-door", "settings" to obj("network" to "tcp")))),
                "outbounds" to JSONArray(listOf(obj("tag" to "elarni-direct", "protocol" to "freedom", "settings" to obj("redirect" to "127.0.0.1:${echo.localPort}")))),
                "routing" to obj("rules" to JSONArray(listOf(obj("type" to "field", "inboundTag" to JSONArray(listOf("elarni-tun")), "process" to JSONArray(listOf("-1")),
                    "outboundTag" to "elarni-direct", "ruleTag" to "elarni-per-app-listed")))))
            Native.call("runXrayFromJson", obj("configJSON" to config.toString()))
            try {
                java.net.Socket("127.0.0.1", inbound).use { client ->
                    client.soTimeout = 5000
                    client.getOutputStream().write(7)
                    assertEquals(7, client.getInputStream().read())
                }
                ui.onNodeWithTag("per-app-connections").performScrollTo().performClick()
                ui.waitUntil(10_000) { ui.onAllNodesWithTag("per-app-connections-list").fetchSemanticsNodes().isNotEmpty() }
                ui.onNodeWithText("Unidentified traffic").assertIsDisplayed()
                ui.onNodeWithText("Direct · Per-app rule").assertIsDisplayed()
                ui.onNodeWithText("127.0.0.1:$inbound · TCP", substring = true).assertIsDisplayed()
                ui.onNodeWithTag("per-app-connections-done").performClick()
            } finally { Native.call("stopXray") }
        }
    }

    @Test fun perAppEachAppTakesItsOwnTargetAndOtherAppsKeepTheMode() {
        call("import", obj("text" to "vless://00000000-0000-4000-8000-000000000001@127.0.0.1:18080?encryption=none#Target%20server"))
        val (first, second) = call("apps").objects("apps").distinctBy { it.getInt("uid") }.take(2).map { it.string("package") }
        call("settings", obj("settings" to obj("perAppMode" to "bypass", "perAppProcesses" to JSONArray(listOf(first, second)), "xrayTunEnabled" to true)))
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Apps & routes")
        click("Per-app routing")
        ui.waitUntil(10_000) { ui.onAllNodesWithText("Selected apps · 2").fetchSemanticsNodes().isNotEmpty() }
        val list = ui.onNodeWithTag("per-app-list")
        fun target(app: String) = hasAnyAncestor(hasTestTag("per-app-target-$app"))
        fun choose(app: String, label: String) {
            list.performScrollToNode(hasTestTag("per-app-target-$app"))
            ui.onNode(hasClickAction() and target(app)).performClick()
            click(label)
        }
        list.performScrollToNode(hasTestTag("per-app-other-apps"))
        ui.onNode(hasText("Follow routing rules") and hasAnyAncestor(hasTestTag("per-app-other-apps"))).assertExists()
        list.performScrollToNode(hasTestTag("per-app-target-$first"))
        ui.onNode(hasText("Direct") and target(first)).assertExists()
        choose(first, "Server · Target server")
        ui.onNode(hasText("Server · Target server") and target(first)).assertExists()
        choose(first, "Block")
        choose(second, "Local proxy…")
        val address = hasSetTextAction() and hasAnyAncestor(isDialog())
        ui.onNode(address).performTextReplacement("socks5://10.0.2.2:1080")
        ui.onNodeWithText("Use a proxy on this device, such as 127.0.0.1.").assertExists()
        ui.onNode(hasText("Use proxy") and hasClickAction()).assertIsNotEnabled()
        ui.onNode(address).performTextReplacement("socks5://127.0.0.1:1080")
        click("Use proxy")
        ui.onNode(hasText("Local proxy · 127.0.0.1:1080") and target(second)).assertExists()
        capture("per-app-targets")
        click("Save changes")
        ui.waitUntil(10_000) { snapshot().settings.mapObject("perAppTargets").length() == 2 }
        assertEquals(obj(first to "block", second to "proxy:socks5://127.0.0.1:1080").toString(), snapshot().settings.getJSONObject("perAppTargets").toString())
        // Only listed apps sends the other apps directly; an app that goes back to the mode's target keeps no entry.
        click("Per-app routing")
        click("Bypass listed apps"); click("Only listed apps")
        list.performScrollToNode(hasTestTag("per-app-other-apps"))
        ui.onNode(hasText("Direct") and hasAnyAncestor(hasTestTag("per-app-other-apps"))).assertExists()
        choose(first, "Follow routing rules")
        click("Save changes")
        ui.waitUntil(10_000) { snapshot().settings.string("perAppMode") == "proxyOnly" }
        assertEquals(obj(second to "proxy:socks5://127.0.0.1:1080").toString(), snapshot().settings.getJSONObject("perAppTargets").toString())
    }

    @Test fun perAppRussianAppsPresetAddsInstalledAppsToBypass() {
        val apps = call("apps").objects("apps").map { it.string("package") }
        // Installed apps stand in for the Russian ones, which the emulator lacks.
        russianApps = listOf(apps[0] to "Preset one", "ru.example.missing" to "Preset missing", apps[1] to "Preset listed", apps[2] to "Preset three")
        try {
            call("settings", obj("settings" to obj("perAppMode" to "off", "perAppProcesses" to JSONArray(listOf(apps[1])))))
            ui.onNode(hasText("Settings") and hasClickAction()).performClick()
            click("Apps & routes")
            click("Per-app routing")
            ui.waitUntil(10_000) { ui.onAllNodesWithText("Selected apps · 1").fetchSemanticsNodes().isNotEmpty() }
            click("Russian apps")
            ui.onNode(hasTestTag("preset-app-${apps[0]}") and hasText("Installed")).assertExists()
            ui.onNode(hasTestTag("preset-app-ru.example.missing") and hasText("Not installed")).assertIsNotEnabled()
            ui.onNode(hasTestTag("preset-app-${apps[1]}") and hasText("Added")).assertIsNotEnabled()
            ui.onNodeWithText("These apps connect directly, but they can still see that a VPN is on: 13 of the 30 most popular Russian apps check network interfaces.").assertExists()
            ui.onNodeWithTag("preset-app-${apps[2]}").performScrollTo().performClick()
            click("Add 1 app")
            ui.onNodeWithText("Bypass listed apps").assertExists()
            click("Save changes")
            ui.waitUntil(10_000) { snapshot().settings.string("perAppMode") == "bypass" }
            assertEquals(setOf(apps[0], apps[1]), snapshot().settings.strings("perAppProcesses").toSet())
            // Only listed apps already sends unlisted apps directly, so it offers no preset.
            click("Per-app routing")
            click("Bypass listed apps"); click("Only listed apps")
            ui.onNodeWithText("Russian apps").assertDoesNotExist()
            click("Cancel")
        } finally { russianApps = RUSSIAN_APPS }
    }

    @Test fun pullToRefreshKeepsTheFirstReview() {
        HTTPFixture().use { one -> HTTPFixture().use { two -> HTTPFixture().use { moved ->
            one.body = "socks://127.0.0.1:18100#One"; two.body = "socks://127.0.0.1:18101#Two"; moved.body = "socks://127.0.0.1:18102#Moved"
            for (feed in listOf(one, two)) call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            val first = snapshot().sources.first().string("id")
            // The first provider now redirects to a destination nobody approved; refreshing the second would clear that review unseen.
            one.redirect = moved.url
            val requests = two.requests.get()
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            ui.onNode(hasScrollToIndexAction()).performTouchInput { swipeDown() }
            ui.waitUntil(10_000) { repo.state.value.approval != null }
            ui.waitUntil(10_000) { !repo.state.value.busy }
            Thread.sleep(2000)
            assertEquals(first, repo.state.value.approval?.string("subscriptionId"))
            assertEquals(requests, two.requests.get())
        } } }
    }
    @Test fun recoveryEditorDropsAServerTheProviderRemoved() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Kept\nsocks://127.0.0.1:18101#Removed"
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            val source = snapshot().sources.single().string("id")
            val kept = snapshot().nodes.single { it.string("name") == "Kept" }.string("id")
            val removed = snapshot().nodes.single { it.string("name") == "Removed" }.string("id")
            call("select", obj("id" to kept))
            call("automation", obj("configuration" to Automation.defaults().put("enabled", true).put("policy", "orderedFallback").put("subscriptionID", source)
                .put("nodeIDs", JSONArray(listOf(removed, kept))).put("targets", JSONArray(listOf(obj("id" to "ui-health", "url" to "http://127.0.0.1:9/health", "expectedStatus" to 204, "expectedBody" to ""))))))
            // The provider drops a chosen server, which turns recovery off; the editor has no row to clear that server with.
            feed.body = "socks://127.0.0.1:18100#Kept"
            call("refresh", obj("id" to source))
            assertFalse(snapshot().data.mapObject("automation").optBoolean("enabled"))
            ui.onNode(hasText("Settings") and hasClickAction()).performClick()
            click("General"); click("Connection recovery")
            click("Enable automatic selection")
            // The last error stays in the state across tests; only a new report counts.
            val reported = repo.state.value.event
            click("Save changes")
            ui.waitUntil(5000) { snapshot().data.mapObject("automation").optBoolean("enabled") || repo.state.value.event != reported }
            assertEquals("The save reported ${repo.state.value.error}", reported, repo.state.value.event)
            assertEquals(listOf(kept), snapshot().data.mapObject("automation").strings("nodeIDs"))
        }
    }
    // Recovery offers the servers of every subscription under its name, and saves which ones enter through Russia.
    @Test fun recoveryEditorOffersServersOfEverySubscription() {
        HTTPFixture().use { feed ->
            call("import", obj("text" to "socks://127.0.0.1:18100#Span%20A"))
            feed.body = "socks://127.0.0.1:18101#%F0%9F%87%B7%F0%9F%87%BA%20Span%20B"
            feed.headers = mapOf("profile-title" to "Second provider")
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            val a = snapshot().nodes.single { it.string("name") == "Span A" }.string("id")
            val b = snapshot().nodes.single { it.string("name").endsWith("Span B") }
            call("select", obj("id" to a))
            call("automation", obj("configuration" to Automation.defaults().put("enabled", true).put("policy", "orderedFallback")
                .put("subscriptionID", snapshot().sourceFor(a).string("id")).put("nodeIDs", JSONArray(listOf(a)))
                .put("targets", JSONArray(listOf(obj("id" to "ui-health", "url" to "http://127.0.0.1:9/health", "expectedStatus" to 204, "expectedBody" to ""))))))
            ui.onNode(hasText("Settings") and hasClickAction()).performClick()
            click("General"); click("Connection recovery")
            ui.onNodeWithText("Second provider").performScrollTo().assertIsDisplayed()
            ui.onNode(isToggleable() and hasText(b.string("name"))).performScrollTo().performClick()
            val reported = repo.state.value.event
            click("Save changes")
            ui.waitUntil(5000) { snapshot().data.mapObject("automation").strings("nodeIDs").size == 2 || repo.state.value.event != reported }
            assertEquals("The save reported ${repo.state.value.error}", reported, repo.state.value.event)
            val saved = snapshot().data.mapObject("automation")
            assertEquals(listOf(a, b.string("id")), saved.strings("nodeIDs"))
            assertEquals(listOf(b.string("id")), saved.strings("russianEntryNodeIDs"))
        }
    }
    @Test fun failedRefreshNamesTheProviderTheCauseAndItsSupportLink() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Provider%20server"
            feed.headers = mapOf("profile-title" to "Northwind", "support-url" to "https://provider.example/support")
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            click("Northwind")
            feed.status = 503
            click("Refresh")
            val cause = "Northwind's server reported an error. Nothing is wrong with Elarni or this device; retry later."
            ui.waitUntil(10_000) { ui.onAllNodes(hasText("$cause The last working servers were kept.")).fetchSemanticsNodes().isNotEmpty() }
            // The toast and the error on the subscription screen each offer the provider's support link.
            ui.onAllNodes(hasText("Contact provider") and hasClickAction()).assertCountEquals(2)
            ui.onNodeWithText("Refresh: $cause").assertExists()
            ui.onNodeWithContentDescription("Back").performClick()
            ui.onNode(hasText("Provider error", substring = true)).assertExists()
        }
    }
    @Test fun providerRoutingNoteSitsInsideItsAssignment() {
        HTTPFixture().use { feed ->
            val profile = obj("Name" to "Provider routing", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "8.8.8.8")
            feed.body = "socks://127.0.0.1:18100#Provider%20server"
            feed.headers = mapOf("profile-title" to "Northwind",
                "routing" to "happ://routing/onadd/" + android.util.Base64.encodeToString(profile.toString().toByteArray(), android.util.Base64.NO_WRAP))
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            ui.onNode(hasText("Routing") and hasClickAction()).performClick()
            // Below the tile, the group's rounded clip cut the note's end; inside, it is part of the tile.
            val tile = hasText("Northwind") and hasText("Set by your provider") and hasClickAction()
            ui.waitUntil(5000) { ui.onAllNodes(tile).fetchSemanticsNodes().isNotEmpty() }
        }
    }
    @Test fun refreshOverrideFieldAndTheIntervalThatApplies() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Provider%20server"
            feed.headers = mapOf("profile-title" to "Northwind", "profile-update-interval" to "6")
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            val id = snapshot().sources.single().string("id")
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            click("Northwind")
            ui.onNodeWithText("Every 6 h").assertExists()
            ui.onNodeWithText("Set by your provider").assertExists()
            click("Change")
            ui.onNodeWithText("Leave empty to follow the provider (6 h). 1–168.").assertExists()
            ui.onNodeWithText("Refresh every (hours) · override").performTextInput("2")
            click("Save changes")
            ui.waitUntil(5000) { snapshot().source(id).mapObject("fetchOptions").string("refreshHours") == "2" }
            ui.waitUntil(5000) { ui.onAllNodesWithText("Every 2 h").fetchSemanticsNodes().isNotEmpty() }
            ui.onNodeWithText("Your override").assertExists()
        }
    }
    @Test fun deviceIDIsCopiedAndResetForOneSubscription() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Provider%20server"
            feed.headers = mapOf("profile-title" to "Northwind", "x-hwid-active" to "1")
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            val id = snapshot().sources.single().string("id")
            fun shown() = call("deviceID", obj("id" to id)).getString("deviceId")
            fun short(value: String) = "${value.take(8)}…${value.takeLast(4)}"
            val sent = feed.hwids.getValue("/feed")
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            click("Northwind")
            ui.onNodeWithText(short(sent)).assertExists()
            ui.onNodeWithText("Registered · set by your provider").assertExists()
            ui.onNode(hasText("Elarni sends each provider a different device ID", substring = true)).assertExists()
            click("Copy")
            ui.runOnIdle { assertEquals(sent, ui.activity.getSystemService(android.content.ClipboardManager::class.java).primaryClip!!.getItemAt(0).text.toString()) }
            click("Reset")
            ui.onNodeWithText("Reset device ID for Northwind?").assertExists()
            ui.onNode(hasText("Northwind will see this device as new.", substring = true)).assertExists()
            click("Cancel")
            assertEquals(sent, shown())
            click("Reset")
            ui.onNode(hasText("Reset") and hasAnyAncestor(isDialog())).performClick()
            ui.waitUntil(5000) { shown() != sent }
            val reset = shown()
            ui.waitUntil(5000) { ui.onAllNodesWithText(short(reset)).fetchSemanticsNodes().isNotEmpty() }
            click("Refresh")
            ui.waitUntil(10_000) { feed.hwids["/feed"] == reset && !repo.state.value.busy }
        }
    }
    @Test fun providerServerIsHiddenAndShownAgain() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Kept%20server\nsocks://127.0.0.1:18101#Unwanted%20server"
            feed.headers = mapOf("profile-title" to "Northwind")
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            click("Northwind")
            click("Unwanted server")
            ui.onAllNodesWithText("Delete server").assertCountEquals(0)
            click("Hide server")
            ui.onNodeWithText("Unwanted server stays hidden after refreshes. Show it again from Hidden servers.").assertExists()
            click("Hide")
            ui.waitUntil(5000) { snapshot().nodes.map { it.string("name") } == listOf("Kept server") }
            click("Northwind")
            val before = feed.requests.get()
            click("Refresh")
            ui.waitUntil(10_000) { feed.requests.get() > before && !repo.state.value.busy }
            assertEquals(listOf("Kept server"), snapshot().nodes.map { it.string("name") })
            ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Hidden servers · 1"))
            click("Show again")
            ui.onNode(hasText("Show again") and hasAnySibling(hasText("Unwanted server"))).performClick()
            ui.waitUntil(5000) { snapshot().nodes.map { it.string("name") } == listOf("Kept server", "Unwanted server") }
            ui.onAllNodesWithText("Hidden servers", substring = true).assertCountEquals(0)
        }
    }
    @Test fun homePullDownRefreshesSubscriptions() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Germany%20Demo"
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            ui.onNode(hasText("Home") and hasClickAction()).performClick()
            ui.waitForIdle()
            feed.body = "socks://127.0.0.1:18100#Germany%20Demo\nsocks://127.0.0.1:18101#Germany%20Pulled"
            val before = feed.requests.get()
            ui.onNode(hasScrollToIndexAction()).performTouchInput { swipeDown() }
            ui.waitUntil(10_000) { snapshot().nodes.any { it.string("name") == "Germany Pulled" } }
            assertTrue(feed.requests.get() > before)
        }
    }
    // Nothing else on Home says that a pull updates subscriptions, and TalkBack cannot pull: a line above the servers
    // says how old they are, offers the gesture until it is used once, and refreshes when tapped.
    @Test fun homeFreshnessLineTeachesThePullAndRefreshesOnTap() {
        val prefs = ui.activity.getSharedPreferences("ui", android.content.Context.MODE_PRIVATE)
        prefs.edit().remove("pulledToRefresh").commit()
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Germany%20Demo"
            call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
            // Home reads the flag when it is composed: leave and come back.
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            ui.onNode(hasText("Home") and hasClickAction()).performClick()
            val list = ui.onNode(hasScrollToIndexAction())
            val line = hasTestTag("subscription-freshness")
            list.performScrollToNode(line)
            ui.onNode(line).assert(hasText("Updated just now", substring = true)).assert(hasText("Pull down to update", substring = true)).assertHasClickAction()
            feed.body = "socks://127.0.0.1:18100#Germany%20Demo\nsocks://127.0.0.1:18101#Germany%20Tapped"
            ui.onNode(line).performClick()
            ui.waitUntil(10_000) { snapshot().nodes.any { it.string("name") == "Germany Tapped" } }
            // A tap is not the gesture: once the refresh ends, the line still teaches it.
            ui.waitUntil(10_000) { ui.onAllNodes(line and hasText("Pull down to update", substring = true)).fetchSemanticsNodes().isNotEmpty() }
            list.performScrollToIndex(0)
            list.performTouchInput { swipeDown() }
            ui.waitUntil(10_000) { prefs.getBoolean("pulledToRefresh", false) }
            ui.waitUntil(10_000) { !repo.state.value.busy }
            list.performScrollToNode(line)
            ui.waitUntil(10_000) { ui.onAllNodes(line and hasText("Updated just now", substring = true)).fetchSemanticsNodes().isNotEmpty() }
            ui.onNode(line).assert(hasText("Pull down to update", substring = true).not())
        }
    }
    @Test fun subscriptionsAndRoutingUseIPhoneSections() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Provider%20server"
            feed.headers = mapOf("profile-title" to "Parity provider", "subscription-userinfo" to "upload=10; download=20; total=1000; expire=2000000000")
            val warning = call("import", obj("text" to feed.url)).getJSONObject("warning")
            call("approveSource", obj("token" to warning.getString("token")))
            val provider = snapshot().sources.single()
            call("import", obj("text" to "socks://127.0.0.1:18101#Local%20server"))
            val local = snapshot().sources.single { it.string("id") != provider.string("id") }
            call("renameSource", obj("id" to local.string("id"), "name" to "Pinned local"))
            call("saveRouting", obj("text" to obj("Name" to "Parity routing", "GlobalProxy" to "true", "RemoteDNSType" to "DoU", "RemoteDNSIP" to "1.1.1.1", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "1.1.1.1").toString()))
            val route = snapshot().routes.single()
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            ui.onNodeWithText("970 B left").assertExists()
            ui.onNodeWithContentDescription("Data remaining").assertExists()
            capture("subscriptions-parity")
            click("Pinned local")
            click("Pin subscription")
            ui.waitUntil(5000) { snapshot().source(local.string("id")).optBoolean("pinned") }
            click("Rename")
            ui.onNodeWithText("Name").performTextReplacement("Renamed local")
            click("Save")
            ui.waitUntil(5000) { snapshot().source(local.string("id")).string("name") == "Renamed local" }
            ui.onNodeWithContentDescription("Back").performClick()
            assertTrue(ui.onNodeWithText("Renamed local").fetchSemanticsNode().boundsInRoot.top < ui.onNodeWithText("Parity provider").fetchSemanticsNode().boundsInRoot.top)
            click("Parity provider")
            click("Provider defaults"); click("Parity routing")
            ui.waitUntil(5000) { snapshot().assignments.string(provider.string("id")) == route.string("id") }
            ui.onNodeWithText("Provider").performScrollTo().assertExists()
            capture("subscription-detail-parity")
            // Its servers take two lines, as on Home.
            val server = hasText("Provider server") and hasClickAction()
            ui.onNode(hasScrollToIndexAction()).performScrollToNode(server)
            val height = ui.onNode(server).getBoundsInRoot().height
            assertTrue("Server row is $height tall", height <= 72.dp)
            ui.onNode(hasText("Routing") and hasClickAction()).performClick()
            ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Assignments"))
            ui.onNodeWithText("Assignments").assertExists()
            ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasTestTag("routing-${route.string("id")}"))
            ui.onNodeWithTag("routing-${route.string("id")}").performClick()
            ui.onNodeWithText("Edit rules and DNS").assertExists()
            ui.onNodeWithText("Edit JSON").assertExists()
            ui.onNodeWithText("Duplicate").assertExists()
            ui.onNodeWithText("Routing data").performScrollTo()
            capture("routing-detail-parity")
            click("Edit rules and DNS")
            capture("routing-rules-parity")
            click("DNS")
            ui.onNodeWithText("Keep domain identity with Fake DNS").assertExists()
            capture("routing-dns-parity")
            click("Advanced")
            ui.onNodeWithText("Profile name").assertExists()
            capture("routing-advanced-parity")
            click("Cancel")
            ui.onNodeWithContentDescription("Back").performClick()
            capture("routing-parity")
            ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
            feed.headers = mapOf("profile-title" to "Parity provider", "subscription-userinfo" to "upload=9223372036854775807; download=9223372036854775807; total=1000; expire=0")
            call("refresh", obj("id" to provider.string("id")))
            ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Data exhausted"))
            ui.onNodeWithText("No expiry").assertExists()
        }
    }

    @Test fun homeOrdersFavoritesFirstChecksExitAndHidesServersTogether() {
        HTTPFixture().use { trace ->
            trace.body = "fl=29f\nip=203.0.113.7\nloc=DE\n"
            // An import keeps one server per endpoint, so each working server has its own SOCKS port.
            val (a, b, d) = List(3) { java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")).use { it.localPort } }
            Native.call("runXrayFromJson", obj("configJSON" to obj("log" to obj("loglevel" to "none"),
                "inbounds" to JSONArray(listOf(a, b, d).map { obj("listen" to "127.0.0.1", "port" to it, "protocol" to "socks", "settings" to obj("auth" to "noauth")) }),
                "outbounds" to JSONArray(listOf(obj("protocol" to "freedom")))).toString()))
            Settings.exitTraceURL = trace.url
            try {
                // The latency test reads the same fixture and compares its whole body, so only the server on port 9 fails it.
                call("settings", obj("settings" to obj("probeURL" to trace.url, "probeExpectedStatus" to 200, "probeExpectedBody" to trace.body)))
                call("import", obj("text" to listOf("A" to a, "B" to b, "C" to 9, "D" to d).joinToString("\n") { (name, port) -> "socks://127.0.0.1:$port#Netherlands%20$name" }))
                fun id(name: String) = snapshot().nodes.single { it.string("name") == name }.getString("id")
                call("select", obj("id" to id("Netherlands D")))
                call("favorite", obj("id" to id("Netherlands B"), "value" to true))
                fun top(name: String) = ui.onNodeWithText(name).fetchSemanticsNode().positionInRoot.y
                ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Netherlands C"))
                assertTrue("A favorite leads its country", top("Netherlands B") < top("Netherlands A"))
                ui.onNodeWithContentDescription("Server options").performClick()
                ui.onNode(hasText("Favorites first") and hasAnyAncestor(isPopup())).performClick()
                ui.waitUntil(5000) { !snapshot().settings.optBoolean("favoritesFirst", true) }
                ui.waitForIdle()
                assertTrue("Provider order without favorites first", top("Netherlands A") < top("Netherlands B"))
                // Check exit reads the trace through the server and says when its name disagrees.
                ui.onNode(hasContentDescription("Server actions") and hasAnyAncestor(hasText("Netherlands A"))).performClick()
                ui.onNode(hasText("Check exit") and hasAnyAncestor(isPopup())).performClick()
                ui.waitUntil(15_000) { ui.onAllNodesWithText("Exit: Germany · 203.0.113.7").fetchSemanticsNodes().isNotEmpty() }
                ui.onNodeWithText("Netherlands A's name says Netherlands, but its exit is in Germany.").assertExists()
                ui.onNodeWithContentDescription("Test visible servers").performClick()
                ui.waitUntil(20_000) { repo.state.value.pings.size == 4 && !repo.state.value.busy }
                val pings = listOf("A", "B", "C", "D").map { repo.state.value.pings.getValue(id("Netherlands $it")) }
                assertEquals(pings.map { it.string("error") }.toString(),
                    listOf("success", "success", "failed", "success"), pings.map { it.string("status") })
                // Select mode keeps the selected server and hides or deletes the others together.
                ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
                click(snapshot().sources.single().string("name"))
                click("Select servers")
                click("Select unreachable")
                ui.onNodeWithText("1 selected").assertExists()
                ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasText("Netherlands D"))
                ui.onNodeWithTag("select-node-${id("Netherlands D")}", useUnmergedTree = true).assertIsNotEnabled()
                ui.onNodeWithTag("select-node-${id("Netherlands B")}", useUnmergedTree = true).performClick()
                ui.onNodeWithText("2 selected").assertExists()
                click("Delete")
                ui.onNodeWithText("Delete 2 servers?").assertExists()
                ui.onNode(hasText("Delete") and hasAnyAncestor(isDialog())).performClick()
                ui.waitUntil(5000) { snapshot().nodes.size == 2 }
                assertEquals(listOf("Netherlands A", "Netherlands D"), snapshot().nodes.map { it.string("name") })
                ui.onNodeWithText("Select unreachable").assertDoesNotExist()
            } finally { Settings.exitTraceURL = Settings.EXIT_TRACE_URL; Native.call("stopXray") }
        }
    }

    @Test fun subscriptionBrowserAndProbeStayWithinTheirGroup() {
        HTTPFixture().use { origin ->
            // A real SOCKS server, so the editor's proxy test reaches the core's response contract.
            val upstream = java.net.ServerSocket(0, 1, java.net.InetAddress.getByName("127.0.0.1")).use { it.localPort }
            Native.call("runXrayFromJson", obj("configJSON" to obj("log" to obj("loglevel" to "none"),
                "inbounds" to JSONArray(listOf(obj("listen" to "127.0.0.1", "port" to upstream, "protocol" to "socks", "settings" to obj("auth" to "noauth")))),
                "outbounds" to JSONArray(listOf(obj("protocol" to "freedom")))).toString()))
            try {
                call("import", obj("text" to "socks://127.0.0.1:$upstream#Scoped%20server"))
                val source = snapshot().sources.single(); val id = source.getString("id")
                call("renameSource", obj("id" to id, "name" to "Scoped group"))
                // Local imports share one group, so the other group is a provider.
                HTTPFixture().use { feed ->
                    feed.body = "socks://127.0.0.1:1#Other%20group%20server"
                    call("approveSource", obj("token" to call("import", obj("text" to feed.url)).getJSONObject("warning").getString("token")))
                }
                val other = snapshot().sources.first { it.string("id") != id }
                call("renameSource", obj("id" to other.getString("id"), "name" to "Other group"))
                call("settings", obj("settings" to obj("probeURL" to origin.url, "probeExpectedStatus" to 200)))
                ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
                click("Scoped group"); click("Browse subscription servers")
                ui.onNodeWithText("Scoped server").assertExists()
                ui.onNodeWithText("Other group server").assertDoesNotExist()
                click("Test subscription servers")
                click("Proxy"); ui.onNodeWithText("Direct TCP").performClick()
                click("Run test")
                ui.waitUntil(10_000) { repo.state.value.pings.values.any { it.string("status") == "success" } }
                val nodeId = source.objects("nodes").single().getString("id")
                assertEquals("success", repo.state.value.pings.getValue(nodeId).string("status"))
                assertFalse(repo.state.value.pings.containsKey(other.objects("nodes").single().getString("id")))
                // The saved defaults expect an empty body; the editor must send it.
                ui.waitUntil(5000) { !repo.state.value.busy }
                click("Direct TCP"); ui.onNodeWithText("Proxy").performClick()
                click("Run test")
                ui.waitUntil(10_000) { !repo.state.value.busy && repo.state.value.pings[nodeId]?.string("protocol") == "proxy" }
                assertEquals("success", repo.state.value.pings.getValue(nodeId).string("status"))
                // The core accepts at most 15 s.
                val tested = repo.state.value.pings.getValue(nodeId).getDouble("timestamp")
                ui.onNodeWithText("Timeout in seconds · 1–15").performTextReplacement("30")
                click("Run test")
                ui.waitUntil(20_000) { !repo.state.value.busy && repo.state.value.pings.getValue(nodeId).getDouble("timestamp") > tested }
                assertEquals("success", repo.state.value.pings.getValue(nodeId).string("status"))
                val direct = call("ping", Settings.probeArgs(snapshot().settings, listOf(nodeId)).put("timeout", 16))
                assertEquals("invalid_input", direct.objects("results").single().string("error"))
            } finally { Native.call("stopXray") }
        }
    }

    @Test fun iosHierarchyKeepsAndroidNavigationAndAppearance() {
        val links = listOf("socks://127.0.0.1:18100#Germany%20Demo", "socks://127.0.0.1:18101#Netherlands%20Demo")
        call("import", obj("text" to links.joinToString("\n")))
        call("select", obj("id" to snapshot().nodes.first().getString("id")))
        assertEquals("evergreen", snapshot().settings.getString("accent"))
        ui.onNodeWithContentDescription("Elarni").assertExists()
        ui.onNodeWithContentDescription("Import profiles").assertHasClickAction().assertHeightIsAtLeast(48.dp)
        ui.onNode(hasText("Connect") and hasClickAction()).assertHeightIsAtLeast(48.dp)
        ui.onNodeWithText("Disconnected").assertExists()
        capture("home-light")
        // Home leaves room for servers; Troubleshooting and recovery are in Settings.
        ui.onAllNodesWithText("Troubleshoot").assertCountEquals(0)
        ui.onAllNodesWithText("Recovery settings").assertCountEquals(0)
        // A server takes two lines, so more of them fit on the first screen.
        val server = hasText("Germany Demo") and isSelected()
        ui.onNode(hasScrollToIndexAction()).performScrollToNode(server)
        val height = ui.onNode(server).getBoundsInRoot().height
        assertTrue("Server row is $height tall", height <= 72.dp)
        ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
        capture("subscriptions-light")
        ui.onNode(hasText("Routing") and hasClickAction()).performClick()
        capture("routing-light")
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        capture("settings-light")
        click("Appearance")
        click("Evergreen"); click("Blue")
        click("Follow system"); click("Dark")
        click("Save changes")
        ui.waitUntil(5000) { snapshot().settings.string("accent") == "blue" && snapshot().settings.string("theme") == "dark" }
        ui.activityRule.scenario.recreate()
        assertEquals("blue", snapshot().settings.getString("accent"))
        ui.onNode(hasText("Home") and hasClickAction()).performClick()
        capture("home-dark-blue")
        call("settings", obj("settings" to obj("accent" to "evergreen")))
        capture("home-dark")
        ui.onNodeWithContentDescription("Import profiles").performClick()
        ui.onNodeWithText("Import from clipboard").assertExists()
        capture("import-dark")
        click("Scan QR code")
        ui.onNodeWithContentDescription("Choose QR image").assertExists()
        ui.onNodeWithText("Photograph QR").assertExists()
        capture("qr-dark")
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        ui.onNodeWithText("Appearance").assertExists()
        ui.onNodeWithContentDescription("Back").performClick()
        ui.onNodeWithText("General").assertExists()
        capture("settings-dark")
    }

    // A rotation must not stack a second Restore screen behind the first.
    @Test fun rotationOnRestoreKeepsOneScreen() {
        ui.runOnUiThread { ui.activity.interaction.restore = "{}" }
        ui.waitUntil(5000) { ui.onAllNodesWithText("Restore replaces this device", substring = true).fetchSemanticsNodes().isNotEmpty() }
        ui.activityRule.scenario.recreate()
        ui.onNodeWithText("Restore replaces this device", substring = true).assertExists()
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        ui.waitForIdle()
        ui.onAllNodesWithText("Restore replaces this device", substring = true).assertCountEquals(0)
    }
    // An import whose destination review vanished unanswered must not move a later, unrelated save.
    @Test fun abandonedImportDoesNotMoveALaterSave() {
        HTTPFixture().use { feed ->
            feed.body = "socks://127.0.0.1:18100#Abandoned"
            ui.onNode(hasText("Settings") and hasClickAction()).performClick()
            click("Server tests")
            ui.runOnUiThread { ui.activity.run("import", obj("text" to feed.url)) }
            ui.waitUntil(10_000) { repo.state.value.approval != null }
            // An applied change clears the review unanswered, as its expiry or a Disconnect would.
            call("settings", obj("settings" to obj("probeMethod" to "HEAD")))
            ui.waitUntil(5000) { repo.state.value.approval == null }
            editSetting("Timeout in seconds · 1–15", "7")
            click("Save changes")
            ui.waitUntil(5000) { snapshot().settings.optInt("probeTimeout") == 7 }
            Thread.sleep(1000); ui.waitForIdle()
            ui.onNodeWithText("Timeout in seconds · 1–15").assertExists()
        }
    }
    // A General draft left open must not revert a sort chosen on Home since.
    @Test fun openGeneralDraftKeepsASortChosenOnHome() {
        call("import", obj("text" to "socks://127.0.0.1:18100#Sort%20fixture"))
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("General")
        ui.onNode(hasText("Home") and hasClickAction()).performClick()
        ui.onNodeWithContentDescription("Server options").performClick()
        ui.onNode(hasText("Lowest latency") and hasAnyAncestor(isPopup())).performClick()
        ui.waitUntil(5000) { snapshot().settings.string("sort") == "latency" }
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("Save changes")
        Thread.sleep(1000); ui.waitUntil(5000) { !repo.state.value.busy }
        assertEquals("latency", snapshot().settings.string("sort"))
    }
    // Leaving a server test drops its unsent expected body, as it drops the other fields there.
    @Test fun serverTestDropsAnUnsentBodyOnBack() {
        call("import", obj("text" to "socks://127.0.0.1:18100#Body%20fixture"))
        call("renameSource", obj("id" to snapshot().sources.single().getString("id"), "name" to "Body group"))
        ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
        click("Body group")
        click("Test subscription servers")
        ui.onNodeWithText("Expected response body").performScrollTo().performTextInput("stale")
        ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }
        click("Test subscription servers")
        ui.onNodeWithText("Expected response body").performScrollTo().assert(!hasText("stale", substring = true))
    }
    // The compiler falls back to a legacy bootstrap key, which must not bring back an IP the form cleared.
    @Test fun aClearedLegacyBootstrapIPStaysCleared() {
        call("saveRouting", obj("text" to obj("Name" to "Legacy DNS", "RemoteDNSType" to "DoH", "RemoteDNSDomain" to "https://dns.google/dns-query",
            "RemoteDns" to "8.8.8.8", "DomesticDNSType" to "DoU", "DomesticDNSIP" to "1.1.1.1").toString()))
        val id = snapshot().routes.single().getString("id")
        ui.onNode(hasText("Routing") and hasClickAction()).performClick()
        click("Legacy DNS")
        click("Edit rules and DNS")
        click("DNS")
        ui.onAllNodesWithText("Resolver or bootstrap IP")[0].performScrollTo().performTextClearance()
        click("Save changes")
        ui.waitUntil(5000) { snapshot().route(id).mapObject("profile").let { it.string("RemoteDNSIP").isEmpty() && it.string("RemoteDns").isEmpty() } }
    }
    // A save leaves the editor open; setting a field back to the value it opened with is still an edit.
    @Test fun otherAppsControlTheConnectionOnlyWhenAllowed() {
        assertFalse(snapshot().settings.getBoolean("allowExternalControl"))
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("General")
        click("Let other apps control the connection")
        ui.waitUntil(5000) { snapshot().settings.getBoolean("allowExternalControl") }
        assertFalse("The running core does not read it", Settings.runtime(snapshot().settings).has("allowExternalControl"))
        // Their broadcasts carry the key shown under the switch; New key replaces it.
        val key = snapshot().data.string("externalControlKey")
        assertTrue(key.isNotEmpty())
        ui.onNodeWithText(key).assertExists()
        click("New key")
        ui.waitUntil(5000) { snapshot().data.string("externalControlKey").let { it.isNotEmpty() && it != key } }
        ui.onNodeWithText(snapshot().data.string("externalControlKey")).assertExists()
        // Shortcuts names what an automation app sends.
        click("Shortcuts")
        ui.onNode(hasText("com.elarni.action.CONNECT", substring = true) and hasText(ui.activity.packageName, substring = true)).assertExists()
    }

    @Test fun untrustedWiFiKeepsTrustedNamesAndAsksForLocation() {
        fun shell(command: String) = android.os.ParcelFileDescriptor.AutoCloseInputStream(InstrumentationRegistry.getInstrumentation().uiAutomation
            .executeShellCommand(command)).bufferedReader().use { it.readText() }
        val name = ui.activity.packageName
        listOf("ACCESS_FINE_LOCATION", "ACCESS_COARSE_LOCATION", "ACCESS_BACKGROUND_LOCATION").forEach { shell("pm grant $name android.permission.$it") }
        shell("cmd location set-location-enabled true")
        try {
            ui.onNode(hasText("Settings") and hasClickAction()).performClick()
            click("General")
            ui.onNodeWithText("Trusted Wi-Fi networks").assertDoesNotExist()
            click("Connect on untrusted Wi-Fi")
            ui.waitUntil(5000) { snapshot().settings.getBoolean("connectOnUntrustedWiFi") }
            assertFalse("The running core does not read it", Settings.runtime(snapshot().settings).has("connectOnUntrustedWiFi"))
            ui.onNodeWithText("Allow location all the time").assertDoesNotExist()
            editSetting("Trusted Wi-Fi networks", "Home\n Office 5G \n\nHome")
            click("Save changes")
            ui.waitUntil(5000) { snapshot().settings.strings("trustedWiFiNetworks") == listOf("Home", "Office 5G") }
            editSetting("Trusted Wi-Fi networks", "x".repeat(33))
            click("Save changes")
            ui.waitUntil(5000) { ui.onAllNodesWithText("Use up to 64 Wi-Fi names of at most 32 bytes each, without tabs.").fetchSemanticsNodes().isNotEmpty() }
            assertEquals(listOf("Home", "Office 5G"), snapshot().settings.strings("trustedWiFiNetworks"))
            ui.onNodeWithContentDescription("Dismiss").performClick()
            // With location off, Settings says what to allow and the button opens Android's location settings.
            shell("cmd location set-location-enabled false")
            // On a fresh Google APIs image Play services covers the app with its own location-off warning; close it.
            fun warning() = shell("dumpsys window").lineSequence().any { "mCurrentFocus" in it && "LocationOffWarningActivity" in it }
            val deadline = android.os.SystemClock.uptimeMillis() + 3000
            while (android.os.SystemClock.uptimeMillis() < deadline && !warning()) Thread.sleep(200)
            if (warning()) {
                shell("input keyevent KEYCODE_BACK")
                ui.waitUntil(10_000) { !warning() }
            }
            ui.activityRule.scenario.recreate()
            // Under load the recreated Activity can be idle before its content is set ("No compose hierarchies found").
            ui.waitUntil(10_000) { runCatching { ui.onAllNodesWithText("Allow").fetchSemanticsNodes().isNotEmpty() }.getOrDefault(false) }
            click("Allow")
            ui.waitUntil(10_000) { ui.activityRule.scenario.state != androidx.lifecycle.Lifecycle.State.RESUMED }
            shell("cmd location set-location-enabled true")
            // Android's location settings open in Elarni's task, so Back returns to Settings.
            shell("input keyevent KEYCODE_BACK")
            ui.waitUntil(10_000) { ui.activityRule.scenario.state == androidx.lifecycle.Lifecycle.State.RESUMED }
            ui.waitUntil(5000) { ui.onAllNodesWithText("Allow location all the time").fetchSemanticsNodes().isEmpty() }
        } finally {
            shell("cmd location set-location-enabled true")
            call("settings", obj("settings" to obj("connectOnUntrustedWiFi" to false, "trustedWiFiNetworks" to JSONArray())))
        }
    }

    @Test fun settingSavedThenSetBackSavesAgain() {
        val field = "Refresh interval"
        val opened = snapshot().settings.getInt("subscriptionAutoUpdateHours")
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        click("General")
        editSetting(field, "${opened + 4}")
        click("Save changes")
        ui.waitUntil(5000) { snapshot().settings.getInt("subscriptionAutoUpdateHours") == opened + 4 }
        editSetting(field, "$opened")
        click("Save changes")
        Thread.sleep(1000); ui.waitUntil(5000) { !repo.state.value.busy }
        assertEquals(opened, snapshot().settings.getInt("subscriptionAutoUpdateHours"))
    }

    // Russian comes from res/values-ru; on Android 13+ the app's own language setting reaches every screen through tr().
    @Test fun russianStringsFollowTheAppLanguage() {
        val app = ui.activity.application
        val russian = app.createConfigurationContext(android.content.res.Configuration(app.resources.configuration)
            .apply { setLocale(java.util.Locale.forLanguageTag("ru")) }).resources
        assertEquals("Подключить", russian.getString(R.string.connect))
        assertEquals(listOf("1 сервер", "2 сервера", "5 серверов", "21 сервер"), listOf(1, 2, 5, 21).map { russian.getQuantityString(R.plurals.server_count, it, it) })
        assertEquals("Показано 8 из 21 приложения", russian.getQuantityString(R.plurals.showing_apps, 21, 8, 21))
        if (android.os.Build.VERSION.SDK_INT < 33) return
        val locales = app.getSystemService(android.app.LocaleManager::class.java)
        fun shows(text: String) = runCatching { ui.onAllNodes(hasText(text) and hasClickAction()).fetchSemanticsNodes().isNotEmpty() }.getOrDefault(false)
        fun resumed(): android.app.Activity? {
            var activity: android.app.Activity? = null
            InstrumentationRegistry.getInstrumentation().runOnMainSync {
                activity = androidx.test.runner.lifecycle.ActivityLifecycleMonitorRegistry.getInstance()
                    .getActivitiesInStage(androidx.test.runner.lifecycle.Stage.RESUMED).firstOrNull()
            }
            return activity
        }
        // The activity restarts in the new language. Compose is queried only once the new one is resumed: a root
        // detached while Compose waits for its next frame leaves that wait looping forever, past waitUntil's timeout.
        fun language(tags: String) {
            val target = android.os.LocaleList.forLanguageTags(tags)
            if (locales.applicationLocales == target) return
            val before = resumed()
            locales.applicationLocales = target
            val deadline = android.os.SystemClock.uptimeMillis() + 10_000
            while (resumed().let { it == null || it === before }) {
                assertTrue("The activity did not restart for language '$tags'", android.os.SystemClock.uptimeMillis() < deadline)
                Thread.sleep(50)
            }
        }
        try {
            language("ru")
            ui.waitUntil(10_000) { shows("Главная") }
            assertEquals("Отключено", statusLabel("disconnected", null))
            ui.onNode(hasText("Настройки") and hasClickAction()).performClick()
            ui.onNodeWithText("Общие").assertExists()
        } finally {
            language("")
            ui.waitUntil(10_000) { shows("Home") }
        }
    }
    // TalkBack's view of each screen: every control and field speaks a name, and the
    // connection state is announced when it changes. From API 34 the Accessibility
    // Test Framework (Accessibility Scanner's engine) checks each window too; its
    // visual findings (contrast, target and text size) are logged, not failed, and so
    // are repeated names: each one found sits under its own heading (Remote and Direct
    // DNS, rule groups) or names a tab and a row of the same thing.
    @OptIn(ExperimentalTestApi::class)
    @Test fun screenReaderNamesEveryControlAndHearsTheConnectionState() {
        val atf = android.os.Build.VERSION.SDK_INT >= 34
        val logged = setOf("TextContrastCheck", "ImageContrastCheck", "TouchTargetSizeCheck", "TextSizeCheck", "DuplicateSpeakableTextCheck")
        val problems = mutableListOf<String>()
        fun SemanticsNode.spoken() = (config.getOrNull(SemanticsProperties.ContentDescription).orEmpty() +
            config.getOrNull(SemanticsProperties.Text).orEmpty().map { it.text }).any { it.isNotBlank() }
        fun audit(screen: String) {
            ui.waitForIdle()
            ui.onAllNodes(SemanticsMatcher("an unnamed control") {
                (SemanticsActions.OnClick in it.config || SemanticsActions.SetText in it.config) && !it.spoken()
            }).fetchSemanticsNodes().forEach { problems += "$screen: unnamed ${it.config.getOrNull(SemanticsProperties.Role) ?: "control"} at ${it.boundsInRoot}" }
            if (!atf) return
            // Only here: enabled, the checks would also run (and throw) inside every click.
            ui.enableAccessibilityChecks(AccessibilityValidator().setRunChecksFromRootView(true)
                .setThrowExceptionFor(AccessibilityCheckResult.AccessibilityCheckResultType.WARNING))
            val roots = ui.onAllNodes(isRoot())
            repeat(roots.fetchSemanticsNodes().size) { index ->
                try { roots[index].tryPerformAccessibilityChecks() } catch (e: AccessibilityViewCheckException) {
                    e.results.forEach { result ->
                        val check = result.sourceCheckClass.simpleName
                        val line = "$screen: $check ${result.type} ${result.getMessage(java.util.Locale.ENGLISH)}"
                        if (check in logged) android.util.Log.w("ElarniA11y", line) else problems += line
                    }
                } catch (e: Throwable) { problems += "$screen: ${e.message}" }
            }
            ui.disableAccessibilityChecks()
        }
        fun back() = ui.runOnIdle { ui.activity.onBackPressedDispatcher.onBackPressed() }

        audit("empty Home")
        call("import", obj("text" to "socks://127.0.0.1:1#Germany%20Visible\nsocks://127.0.0.1:2#Netherlands%20Hidden"))
        call("renameSource", obj("id" to snapshot().sources.single().string("id"), "name" to "Audit local"))
        ui.waitUntil(5000) { ui.onAllNodesWithText("Germany Visible").fetchSemanticsNodes().isNotEmpty() }
        audit("Home")
        // The state line speaks for the connection artwork, which stays decorative as on iPhone and desktop.
        ui.onNode(hasText("Disconnected") and SemanticsMatcher.expectValue(SemanticsProperties.LiveRegion, LiveRegionMode.Polite)).assertExists()
        ui.onNode(hasScrollToIndexAction()).performScrollToNode(hasContentDescription("Server actions"))
        ui.onAllNodesWithContentDescription("Server actions").onFirst().performClick()
        audit("server actions")
        ui.onNode(hasText("Details") and hasAnyAncestor(isPopup())).performClick()
        audit("server details")
        back()
        ui.onNode(hasText("Subscriptions") and hasClickAction()).performClick()
        audit("Subscriptions")
        click("Audit local")
        audit("subscription")
        ui.onNodeWithContentDescription("Back").performClick()
        ui.onNode(hasText("Routing") and hasClickAction()).performClick()
        audit("Routing")
        click("New profile")
        audit("routing editor")
        click("DNS")
        audit("routing editor DNS")
        click("Advanced")
        audit("routing editor Advanced")
        repeat(3) { if (ui.onAllNodesWithContentDescription("Back").fetchSemanticsNodes().isNotEmpty()) back() }
        ui.onNode(hasText("Settings") and hasClickAction()).performClick()
        audit("Settings")
        listOf("General", "Appearance", "Connection", "DNS", "Apps & routes", "Advanced", "Server tests", "Backup and repair", "System info", "Route table").forEach { title ->
            click(title)
            audit("Settings $title")
            back()
        }
        click("Backup and repair"); click("Troubleshooting")
        audit("Troubleshooting")
        back()
        click("Logs")
        audit("Logs")
        assertTrue(problems.joinToString("\n"), problems.isEmpty())
    }
    private fun capture(name: String) {
        ui.waitForIdle()
        // Let native drawing and Material press feedback settle before capture.
        android.os.SystemClock.sleep(500)
        ui.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        val file = File(ui.activity.getExternalFilesDir(null), "design-$name.png")
        file.outputStream().use { assertTrue(bitmap.compress(android.graphics.Bitmap.CompressFormat.PNG, 100, it)) }
        bitmap.recycle()
    }
}
