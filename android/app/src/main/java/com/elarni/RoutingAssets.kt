package com.elarni

import android.content.Context
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream

class RoutingAssets(context: Context) {
    private val root = File(context.noBackupFilesDir, "routing-assets").apply { mkdirs() }
    fun directory(revision: String): String {
        if (revision.isEmpty()) return ""
        if (!Regex("^[a-f0-9]{64}$").matches(revision)) throw AppFailure("invalid_assets")
        val file = File(root, revision)
        if (!file.isDirectory) throw AppFailure("assets_unavailable")
        return file.absolutePath
    }
    fun prepare(catalog: Catalog, id: String, refresh: Boolean = false, only: String = "") {
        val route = catalog.route(id)
        val profile = route.getJSONObject("profile")
        val sources = mapOf("geoip" to profile.string("Geoipurl"), "geosite" to profile.string("Geositeurl")).filterValues { it.isNotEmpty() }
        if (sources.isEmpty()) { route.remove("assetRevision"); route.put("geofileStatus", "ready").put("skippedGeodata", JSONArray()); return }
        // After a rule edit the route keeps only the earlier download, to reduce again.
        val previous = route.string("assetRevision").ifEmpty { route.string("originalAssetRevision") }.takeIf { runCatching { directory(it) }.isSuccess }.orEmpty()
        // Direct and Block rules and domestic DNS domains may name codes the geofiles lack,
        // which the core then skips; Proxy rules and servers need their codes.
        val selectors = mutableSetOf<String>(); val optional = mutableSetOf<String>()
        fun collect(value: Any?, into: MutableSet<String> = selectors) {
            when (value) {
                // Xray reads a leading ! on an IP rule like one before the code.
                is String -> if (listOf("geoip:", "geosite:", "ext:", "ext-ip:", "ext-site:", "ext-domain:").any { value.trimStart('!').startsWith(it) }) into.add(value)
                is JSONObject -> value.keys().forEach { collect(value.get(it), into) }
                is JSONArray -> (0 until value.length()).forEach { collect(value.get(it), into) }
            }
        }
        val model = route.getJSONObject("routeModel").copy()
        model.objects("rules").forEach { collect(it, if (it.string("action") in setOf("direct", "block")) optional else selectors) }
        model.remove("rules")
        collect(model.optJSONObject("dnsPolicy")?.remove("domesticDomains"), optional)
        collect(model)
        // The servers' own configurations; compiling them would also add this route's rules, Direct and Block ones included.
        catalog.nodes.filter { catalog.routeFor(it.string("id"))?.string("id") == id && it.string("format") == "xrayProfile" }.forEach { collect(it.getJSONObject("config")) }
        val revision = newId(); val stage = File(root, revision)
        if (!stage.mkdir()) throw AppFailure("assets_unavailable")
        var committed = false
        try {
            val files = JSONArray(); val skipped = mutableListOf<String>(); val missing = mutableListOf<String>()
            var status = if (profile.string("UseChunkFiles") == "true") "ready" else "disabled"
            sources.forEach { (name, url) ->
                val old = if (previous.isEmpty()) null else File(directory(previous), "$name.original.dat")
                // Originals stay on disk: a runetfreedom geosite.dat is 85 MB, against a 256 MB app heap.
                val original = File(stage, "$name.original.dat"); val reduced = File(stage, "$name.dat")
                fun stored() = old?.takeIf { it.isFile }?.inputStream()?.use { input -> FileOutputStream(original).use { input.copyTo(it); it.fd.sync() } }
                    ?: throw AppFailure("assets_unavailable")
                // The stored original's ETag and Last-Modified hold only for the link it came from.
                var source = old?.takeIf { it.isFile }?.let { File(it.parentFile, "$name.source.json") }?.takeIf { it.isFile && it.length() <= 16384 }
                    ?.let { runCatching { JSONObject(it.readText()) }.getOrNull() }?.takeIf { it.string("url") == url } ?: JSONObject()
                if (old?.isFile == true && (!refresh || only.isNotEmpty() && only != name)) stored() else {
                    val response = catalog.resource(id, url, "geofile", source, original)
                    if (response.optBoolean("notModified")) stored()
                    else source = obj("url" to url, "etag" to response.string("etag"), "lastModified" to response.string("lastModified"))
                }
                val result = try { JSONObject(LibXray.reduceAndroidGeoFile(name, original.absolutePath, reduced.absolutePath, JSONArray(selectors.toList()).toString(), JSONArray(optional.toList()).toString(), profile.string("UseChunkFiles") == "true")) }
                    catch (error: Exception) { throw AppFailure(error.message?.takeIf { it in setOf("input_too_large", "assets_unavailable") } ?: "invalid_geodata") }
                // Collect the codes both files lack, then name them together.
                if (result.has("missing")) { missing += result.strings("missing"); return@forEach }
                skipped += result.strings("skipped")
                if (result.string("status") == "fullFileFallback") status = "fullFileFallback"
                if (source.string("etag").isNotEmpty() || source.string("lastModified").isNotEmpty())
                    FileOutputStream(File(stage, "$name.source.json")).use { it.write(source.toString().toByteArray()); it.fd.sync() }
                Native.call("countGeoData", obj("name" to name, "geoType" to if (name == "geoip") "ip" else "domain", "datDir" to stage.absolutePath))
                files.put(obj("name" to name, "source" to url, "bytes" to reduced.length(), "originalBytes" to original.length(), "updatedAt" to now()))
            }
            if (missing.isNotEmpty()) throw AppFailure("missing_geodata:" + missing.joinToString(","))
            val same = previous.isNotEmpty() && listOf("geoip.dat", "geoip.original.dat", "geosite.dat", "geosite.original.dat").all { name ->
                val a = File(stage, name); val b = File(directory(previous), name)
                (!a.exists() && !b.exists()) || a.isFile && b.isFile && sameContent(a, b)
            }
            // Only the validators may have changed; the core never reads them.
            if (same) listOf("geoip.source.json", "geosite.source.json").forEach { name ->
                val kept = File(directory(previous), name)
                if (!File(stage, name).renameTo(kept)) kept.delete()
            }
            route.put("assetRevision", if (same) previous else revision).put("geofiles", files)
                .put("geofileStatus", "ready").put("geofileError", JSONObject.NULL).put("reductionStatus", status).put("skippedGeodata", JSONArray(skipped))
                .put("nextGeoRefreshAt", now() + 7 * 86400).put("geoFailures", 0)
            route.remove("originalAssetRevision")
            committed = !same
        } catch (_: OutOfMemoryError) {
            // OutOfMemoryError is no Exception.
            throw AppFailure("input_too_large")
        } finally { if (!committed) stage.deleteRecursively() }
    }
    /** Compares two files a chunk at a time; an original may be far larger than the app heap allows reading whole. */
    private fun sameContent(a: File, b: File): Boolean {
        if (a.length() != b.length()) return false
        fun java.io.InputStream.fill(buffer: ByteArray): Int {
            var n = 0
            while (n < buffer.size) { val count = read(buffer, n, buffer.size - n); if (count < 0) break; n += count }
            return n
        }
        a.inputStream().use { x -> b.inputStream().use { y ->
            val p = ByteArray(65536); val q = ByteArray(65536)
            while (true) {
                val n = x.fill(p)
                // Past n both buffers still hold the previous, equal chunk.
                if (n != y.fill(q) || !p.contentEquals(q)) return false
                if (n < p.size) return true
            }
        } }
    }
    fun retire(keep: Set<String>) {
        root.listFiles()?.filter { it.isDirectory && Regex("^[a-f0-9]{64}$").matches(it.name) && it.name !in keep }?.forEach { it.deleteRecursively() }
    }
}
