package com.elarni

import android.Manifest
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Intent
import android.net.Uri
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.provider.Settings as AndroidSettings
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction

class InteractionModel : ViewModel() {
    var incoming by mutableStateOf<String?>(null)
    // ACTION_VIEW links come from web pages and other apps; AppUI confirms them.
    var linkImport by mutableStateOf<String?>(null)
    var linkStop by mutableStateOf(false)
    var restore by mutableStateOf<String?>(null)
    var fileAction = "import"
    var export: ByteArray? = null
    var camera: Uri? = null
    var share by mutableStateOf<JSONObject?>(null)
    var dismissEditor by mutableStateOf(false)
    var notice by mutableStateOf<String?>(null)
    var importDestination by mutableStateOf<String?>(null)
    var importing = false
    var importSources = emptyList<String>()
    var reviewingEditor = false
    /** Set while the open editor has unsaved edits: saves them for the move the user asked for. */
    var leaveSave: ((String) -> Unit)? = null
    /** The move a draft save was started for ("back", "top", "tab <page>", "open <detail> <id>"); AppUI runs it once the draft is stored. */
    var leaveAfterSave: String? = null
    var leave by mutableStateOf<String?>(null)
    /** "saving" from a flipped switch until its save ends, then "saved" for a moment; the top bar shows it. */
    var saveStatus by mutableStateOf("")
    var lastErrorEvent = -1L
    var consentGeneration: Long? = null
    private val drafts = mutableMapOf<String, MutableState<String>>()
    private val fieldDrafts = mutableMapOf<String, SnapshotStateMap<String, String>>()
    fun draft(key: String, initial: () -> String): MutableState<String> = drafts.getOrPut(key) { mutableStateOf(initial()) }
    fun fields(key: String, initial: () -> Map<String, String>): SnapshotStateMap<String, String> = fieldDrafts.getOrPut(key) { mutableStateMapOf<String, String>().apply { putAll(initial()) } }
    fun discardDrafts() { drafts.clear(); fieldDrafts.clear(); reviewingEditor = false; leaveAfterSave = null; if (saveStatus == "saving") saveStatus = "" }
    fun discardDrafts(prefixes: List<String>) {
        drafts.keys.removeAll { key -> prefixes.any(key::startsWith) }
        fieldDrafts.keys.removeAll { key -> prefixes.any(key::startsWith) }
        reviewingEditor = false; leaveAfterSave = null
        // A switch still waiting out its pause went with the draft.
        if (saveStatus == "saving") saveStatus = ""
    }
}

class MainActivity : ComponentActivity() {
    private val app get() = application as ElarniApplication
    val repository get() = app.repository
    lateinit var interaction: InteractionModel
        private set
    private val vpnConsent = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) { result ->
        val generation = interaction.consentGeneration; interaction.consentGeneration = null
        if (generation != null && repository.isCurrentRequest(generation)) {
            if (result.resultCode == RESULT_OK) connect(generation) else repository.report(AppFailure("vpn_consent_required"))
        }
    }
    private val notifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) { /* The foreground connection remains accessible in Android's active-apps UI. */ }
    private val openFile = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> if (uri != null) read(uri, interaction.fileAction) }
    private val createFile = registerForActivityResult(ActivityResultContracts.CreateDocument("application/octet-stream")) { uri ->
        val bytes = interaction.export; interaction.export = null
        if (uri != null && bytes != null) repository.scope.launch {
            try {
                contentResolver.openOutputStream(uri, "wt")?.use { it.write(bytes) } ?: throw AppFailure("file_unavailable")
                withContext(Dispatchers.Main) { interaction.notice = tr(R.string.file_saved) }
            }
            catch (_: Exception) { repository.report(AppFailure("file_unavailable")) }
        }
        else if (uri != null) repository.report(AppFailure("export_expired"))
    }
    // Each answer to the camera permission makes the QR screen check it again.
    var cameraAnswers by mutableIntStateOf(0)
    private val cameraPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { cameraAnswers++ }
    fun cameraAllowed() = checkSelfPermission(Manifest.permission.CAMERA) == android.content.pm.PackageManager.PERMISSION_GRANTED
    // After a final no, Android shows no dialog; only the app's settings can turn the camera on.
    fun allowCamera() = if (cameraAnswers > 0 && !shouldShowRequestPermissionRationale(Manifest.permission.CAMERA)) appSettings() else cameraPermission.launch(Manifest.permission.CAMERA)
    // Each answer to a location request makes Settings check the Wi-Fi rule's access again.
    var wifiAnswers by mutableIntStateOf(0)
    private val backgroundLocation = registerForActivityResult(ActivityResultContracts.RequestPermission()) { wifiAnswers++ }
    // Android grants location while in use first; all the time is a second request, answered on Android's own screen.
    private val location = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        wifiAnswers++
        if (granted[Manifest.permission.ACCESS_FINE_LOCATION] == true) backgroundLocation.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
    }
    fun allowWiFiNames() {
        val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == android.content.pm.PackageManager.PERMISSION_GRANTED
        when {
            !getSystemService(android.location.LocationManager::class.java).isLocationEnabled -> startActivity(Intent(android.provider.Settings.ACTION_LOCATION_SOURCE_SETTINGS))
            // After a final no, Android shows no dialog; only the app's settings can allow it.
            wifiAnswers > 0 && !shouldShowRequestPermissionRationale(if (fine) Manifest.permission.ACCESS_BACKGROUND_LOCATION else Manifest.permission.ACCESS_FINE_LOCATION) -> appSettings()
            fine -> backgroundLocation.launch(Manifest.permission.ACCESS_BACKGROUND_LOCATION)
            else -> location.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        }
    }
    private val camera = registerForActivityResult(ActivityResultContracts.TakePicture()) { success ->
        val uri = interaction.camera; interaction.camera = null
        if (success && uri != null) read(uri, "qr")
    }
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        interaction = ViewModelProvider(this)[InteractionModel::class.java]
        // The system may end the process while a picker or the camera is open; the ViewModel is new then.
        savedInstanceState?.let { saved ->
            saved.getString("fileAction")?.let { interaction.fileAction = it }
            if (interaction.camera == null) interaction.camera = saved.getString("camera")?.let(Uri::parse)
        }
        setContent { ElarniUI(this) }
        if (savedInstanceState == null) receive(intent)
        repository.scope.launch { repository.awaitReady(); repository.maintenance() }
    }
    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putString("fileAction", interaction.fileAction)
        interaction.camera?.let { outState.putString("camera", it.toString()) }
    }
    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); setIntent(intent); receive(intent) }
    private fun receive(intent: Intent) {
        // Recents reopens a task with the Intent that first opened it, which asks for nothing new.
        if (intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY != 0) return
        if (intent.action == "com.elarni.OPEN_CONNECT") { connect(); return }
        if (intent.action == Intent.ACTION_VIEW) intent.dataString?.let { link ->
            val uri = runCatching { java.net.URI(link) }.getOrNull()
            val action = if (link == link.trim() && uri != null && uri.scheme?.lowercase() in listOf("elarni", "incy", "happ") &&
                uri.rawUserInfo == null && uri.port == -1 && uri.rawQuery == null && uri.rawFragment == null && uri.rawPath in listOf("", "/")) uri.host?.lowercase() else null
            when (action) {
                "connect", "open" -> connect()
                "disconnect", "close" -> interaction.linkStop = true
                "toggle" -> if (repository.state.value.connection in listOf("connected", "connecting", "paused")) interaction.linkStop = true else connect()
                "status" -> interaction.notice = tr(R.string.connection, repository.state.value.connection)
                else -> interaction.linkImport = link
            }
        }
        if (intent.action == Intent.ACTION_SEND) {
            var text: String? = null; var stream: Uri? = null
            // Any app may send this; an extra that is no Uri is ignored, not cast, and so are extras of a class this app lacks, which throw.
            @Suppress("DEPRECATION") runCatching { text = intent.getStringExtra(Intent.EXTRA_TEXT); stream = intent.extras?.get(Intent.EXTRA_STREAM) as? Uri }
            text?.let { interaction.incoming = it }
            stream?.let { read(it, if (intent.type?.startsWith("image/") == true) "qr" else "import") }
        }
    }
    fun connect(generation: Long = repository.beginConnectionRequest()) {
        repository.scope.launch {
            repository.awaitReady()
            withContext(Dispatchers.Main) {
                if (!repository.isCurrentRequest(generation)) return@withContext
                val vpn = repository.state.value.catalog.mapObject("settings").optBoolean("xrayTunEnabled", true)
                val consent = if (vpn) VpnService.prepare(this@MainActivity) else null
                if (consent != null) { interaction.consentGeneration = generation; vpnConsent.launch(consent) }
                else {
                    if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != android.content.pm.PackageManager.PERMISSION_GRANTED) notifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                    repository.scope.launch { try { repository.requestConnect(generation = generation) } catch (error: Exception) { if (error !is AppFailure || error.code != "cancelled") repository.report(error) } }
                }
            }
        }
    }
    fun run(command: String, args: JSONObject = JSONObject(), failed: () -> Unit = {}, done: (JSONObject) -> Unit = {}) {
        // Only an approval continues an import; an import whose review vanished must not move a later save.
        if (command !in listOf("import", "approveSource", "approveResource")) interaction.importing = false
        if (command == "import") {
            val current = Catalog(repository.state.value.catalog)
            interaction.importing = true
            interaction.importSources = current.sources.map { it.string("id") + ":" + it.optDouble("lastSuccessfulFetch", 0.0) } + current.nodes.map { it.string("configurationRevision", it.string("id")) }
        }
        repository.scope.launch {
            try {
                val result = if (command == "ping") repository.ping(args) else repository.execute(command, args)
                withContext(Dispatchers.Main) {
                    if (command == "reject") { interaction.reviewingEditor = false; interaction.leaveAfterSave = null; interaction.importing = false }
                    if (interaction.importing && result.optBoolean("saved")) {
                        val current = Catalog(repository.state.value.catalog)
                        val sources = current.sources.map { it.string("id") + ":" + it.optDouble("lastSuccessfulFetch", 0.0) } + current.nodes.map { it.string("configurationRevision", it.string("id")) }
                        interaction.importDestination = if (sources == interaction.importSources) "routing" else "home"
                        interaction.importing = false
                    }
                    if (interaction.reviewingEditor && result.optBoolean("saved")) {
                        interaction.reviewingEditor = false
                        // Saved for a move: AppUI closes the editor and goes where the user was heading.
                        val move = interaction.leaveAfterSave; interaction.leaveAfterSave = null
                        if (move != null) interaction.leave = move else interaction.dismissEditor = true
                    }
                    if (result.optBoolean("reconnectAfterReview")) interaction.notice = tr(R.string.destination_approved_tap_connect)
                    done(result)
                }
            }
            catch (_: Exception) {
                // A failed approval retains its warning and editable draft.
                withContext(Dispatchers.Main) {
                    if (command !in listOf("approveSource", "approveResource")) { interaction.reviewingEditor = false; interaction.leaveAfterSave = null; interaction.importing = false }
                    failed()
                }
            }
        }
    }
    /** Refreshes in turn and stops at a review, which a later refresh would clear or replace before the user sees it. */
    fun refreshAll(ids: List<String>) =
        repository.scope.launch {
            for (id in ids) {
                if (repository.state.value.approval != null) break
                try { repository.execute("refresh", obj("id" to id)) } catch (_: AppFailure) { }
            }
        }
    /** Saves an editor's draft and closes the editor, or with [move] makes that move, once the draft is stored. */
    fun saveReviewed(command: String, args: JSONObject, move: String? = null) {
        interaction.reviewingEditor = true; interaction.leaveAfterSave = move
        run(command, args)
    }
    /** A save the top bar reports: "Saving…", then "Saved". */
    fun runShown(command: String, args: JSONObject, failed: () -> Unit = {}, done: (JSONObject) -> Unit = {}) {
        interaction.saveStatus = "saving"
        // A save that stopped at a review is not stored yet.
        run(command, args, { interaction.saveStatus = ""; failed() }) { if (it.optBoolean("saved")) { interaction.saveStatus = "saved"; done(it) } else interaction.saveStatus = "" }
    }
    // The VPN excludes this app (Platform.kt), so while connected, test cores, direct TCP and ICMP
    // reach other servers outside the tunnel; only the selected server's proxy test uses the tunnel.
    fun testServers(ids: List<String>, sourceId: String = "") =
        run("ping", Settings.probeArgs(Catalog(repository.state.value.catalog).settings, ids).put("sourceId", sourceId))
    fun checkExit(id: String) = run("ping", Settings.exitArgs(id))
    fun paste() {
        val text = getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.coerceToText(this)?.toString()
        if (text.isNullOrBlank()) interaction.notice = tr(R.string.the_clipboard_is_empty_copy_a)
        else interaction.incoming = text
    }
    fun pick(action: String) { interaction.fileAction = action; openFile.launch(if (action == "qr") arrayOf("image/*") else arrayOf("*/*")) }
    fun photographQR() {
        try {
            val file = File(cacheDir, "shared").apply { mkdirs() }.resolve("camera-qr.jpg")
            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            interaction.camera = uri; camera.launch(uri)
        } catch (_: Exception) { repository.report(AppFailure("camera_unavailable")) }
    }
    private fun read(uri: Uri, action: String) {
        repository.scope.launch {
            try {
                val limit = (if (action == "restore") 12 else if (action == "qr") 8 else 4) * 1024 * 1024
                val bytes = contentResolver.openInputStream(uri)?.use { it.readBounded(limit) } ?: throw AppFailure("file_unavailable")
                val text = if (action == "qr") Native.qr(bytes) else Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT).onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
                withContext(Dispatchers.Main) { if (action == "restore") interaction.restore = text else interaction.incoming = text }
            } catch (error: Exception) { repository.report(if (error is AppFailure) error else AppFailure("file_unavailable")) }
        }
    }
    fun save(text: String, name: String) { interaction.export = text.toByteArray(Charsets.UTF_8); createFile.launch(name) }
    // Outside the repository lock, so a mark lands while a connect is stuck.
    fun markRecording() {
        repository.scope.launch {
            try {
                repository.engine.markRecording()
                val time = java.time.LocalTime.now().withNano(0)
                withContext(Dispatchers.Main) { interaction.notice = tr(R.string.problem_marked_at, time.toString()) }
            } catch (error: Exception) { repository.report(if (error is AppFailure) error else AppFailure("recording_failed")) }
        }
    }
    fun saveRecording() {
        repository.scope.launch {
            try {
                val bytes = repository.engine.exportRecording()
                withContext(Dispatchers.Main) { interaction.export = bytes; createFile.launch("elarni-recording.zip") }
            } catch (error: Exception) { repository.report(if (error is AppFailure) error else AppFailure("recording_failed")) }
        }
    }
    fun copy(text: String, sensitive: Boolean = false) { getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Elarni", text).apply {
        // Android 13 and later then keep the text out of the clipboard preview.
        if (sensitive) description.extras = android.os.PersistableBundle().apply { putBoolean("android.content.extra.IS_SENSITIVE", true) }
    }) }
    fun shareText(text: String) { startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, text), tr(R.string.share_profile))) }
    fun shareQR(png: String) = shareFile("profile-qr.png", "image/png", tr(R.string.share_qr_code)) { android.util.Base64.decode(png, android.util.Base64.DEFAULT) }
    fun shareFile(name: String, type: String, title: String, content: () -> ByteArray) {
        try {
            val file = File(cacheDir, "shared").apply { mkdirs() }.resolve(name)
            file.writeBytes(content())
            val uri = FileProvider.getUriForFile(this, "$packageName.files", file)
            startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType(type).putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), title))
        } catch (_: Exception) { repository.report(AppFailure("file_unavailable")) }
    }
    fun openURL(url: String, telegram: Boolean = false) {
        try {
            if (Catalog.safeURL(url) == null && !(telegram && url.startsWith("tg://proxy?"))) throw AppFailure("invalid_target")
            startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)))
        } catch (_: Exception) { repository.report(AppFailure("link_unavailable")) }
    }
    fun vpnSettings() { startActivity(Intent(AndroidSettings.ACTION_VPN_SETTINGS)) }
    fun appSettings() { startActivity(Intent(AndroidSettings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) }
}
