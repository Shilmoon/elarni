package com.elarni

import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.security.SecureRandom
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

internal fun obj(vararg pairs: Pair<String, Any?>) = JSONObject().apply {
    pairs.forEach { (key, value) -> put(key, value ?: JSONObject.NULL) }
}
internal fun JSONObject.copy() = JSONObject(toString())
internal fun JSONObject.objects(key: String): List<JSONObject> = optJSONArray(key)?.objects() ?: emptyList()
internal fun JSONArray.objects(): List<JSONObject> = (0 until length()).map { getJSONObject(it) }
internal fun JSONArray.strings(): List<String> = (0 until length()).map { getString(it) }
internal fun JSONObject.strings(key: String) = optJSONArray(key)?.strings() ?: emptyList()
internal fun JSONObject.mapObject(key: String) = optJSONObject(key) ?: JSONObject()
internal fun JSONObject.string(key: String, fallback: String = ""): String = if (isNull(key)) fallback else optString(key, fallback)
internal fun JSONObject.merge(other: JSONObject) = apply { other.keys().forEach { put(it, other.get(it)) } }
internal fun newId(): String = ByteArray(32).also(SecureRandom()::nextBytes).joinToString("") { "%02x".format(it.toInt() and 255) }
internal fun now() = System.currentTimeMillis() / 1000.0
internal fun java.io.InputStream.readBounded(limit: Int): ByteArray {
    val output = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(16 * 1024)
    while (true) {
        val count = read(buffer)
        if (count < 0) break
        if (output.size() + count > limit) throw AppFailure("input_too_large")
        output.write(buffer, 0, count)
    }
    return output.toByteArray()
}

class AppFailure(val code: String) : Exception(code)

object NativeBindings {
    init { System.loadLibrary("elarni_jni") }
    external fun domain(input: ByteArray): ByteArray
}

/** All native error messages are replaced by bounded codes before reaching UI. */
object Native {
    private val operations = ConcurrentHashMap<String, String>()
    val runtimeLock = Any()
    fun domain(operation: String, payload: JSONObject): JSONObject =
        domain(operation, obj("schemaVersion" to 1, "operation" to operation, "payload" to payload).toString().toByteArray(Charsets.UTF_8))
    /** [request] is the whole encoded envelope. */
    fun domain(operation: String, request: ByteArray): JSONObject = try {
        JSONObject(String(NativeBindings.domain(request), Charsets.UTF_8))
    } catch (_: Exception) { throw AppFailure(if (operation == "compileProfile") "unsupported_profile" else "invalid_input") }

    // A download failure keeps its class, so the app can say whose fault it is.
    private val passedThrough = setOf("hwid_required", "hwid_limit", "invalid_target", "fetch_cancelled", "invalid_backup", "invalid_backup_password", "probe_cancelled", "probe_busy",
        "fetch_failed", "dns_failed", "provider_unreachable", "provider_error", "rate_limited", "subscription_denied", "subscription_unavailable", "recording_empty",
        "input_too_large")

    fun call(method: String, payload: JSONObject = JSONObject()): JSONObject {
        val raw = LibXray.invoke(obj("apiVersion" to 1, "method" to method, "payload" to payload).toString())
        val response = JSONObject(raw)
        if (!response.optBoolean("success")) {
            // A cancelled server test returns the transport code "canceled".
            val code = response.string("error").let { if (it == "canceled") "probe_cancelled" else it }
            throw AppFailure(if (code in passedThrough) code else when(method) {
                "importClientProfiles", "normalizeClientInput" -> "unsupported_profile"
                "runXrayFromJson" -> "connection_failed"
                "ping" -> "ping_failed"
                "openCatalogBackup", "sealCatalogBackup", "validateCatalogBackup" -> "invalid_backup"
                "diagnostics" -> "recording_failed"
                else -> "operation_failed"
            })
        }
        return response.optJSONObject("data") ?: JSONObject()
    }

    fun cancellable(method: String, payload: JSONObject): JSONObject {
        val kind = if (method == "ping") "Probe" else "Fetch"
        val id = UUID.randomUUID().toString()
        val request = payload.copy().put("operationId", id)
        call("prepare$kind", request)
        operations[id] = kind
        try { return call(method, request) }
        finally {
            operations.remove(id)
            runCatching { call("release$kind", obj("operationId" to id)) }
        }
    }

    fun cancelOperations(kind: String? = null) {
        operations.forEach { (id, running) -> if (kind == null || running == kind) runCatching { call("cancel$running", obj("operationId" to id)) } }
    }

    fun qr(bytes: ByteArray): String = try { LibXray.decodeAndroidQRImage(bytes) }
        catch (_: Exception) { throw AppFailure("invalid_qr_image") }
}
