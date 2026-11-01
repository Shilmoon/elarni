package com.elarni

import android.content.Context
import android.graphics.BitmapFactory
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import org.json.JSONArray
import java.util.Locale

/** A provider label, not a measured server position. Data matches the desktop. */
data class ServerLocation(val code: String, val name: String)

class ServerLocations(context: Context) {
    private val assets = context.assets
    private val flagImages = mutableMapOf<String, ImageBitmap?>()
    private val locations = mutableMapOf<String, ServerLocation>()
    private val prefixes = mutableMapOf<String, String>()
    private val names = mutableMapOf<String, MutableSet<String>>()
    private val namePattern: Regex
    private val flags = Regex("[\\x{1F1E6}-\\x{1F1FF}]{2}")
    private val prefix = Regex("^(?:\\[|\\()?([A-Z]{2,3})(?=$|[\\s\\]\\)\\-_|•])")
    // US places whose names contain a country or territory name, as on the desktop.
    private val places = Regex("(^|[^\\p{L}\\p{N}])(new jersey|jersey city|new mexico|нью-джерси|нью-мексико)(?=$|[^\\p{L}\\p{N}])", RegexOption.IGNORE_CASE)
    init {
        val data = JSONArray(context.assets.open("server-locations.json").bufferedReader().use { it.readText() })
        for (index in 0 until data.length()) {
            val row = data.getJSONObject(index); val code = row.getString("code")
            locations[code] = ServerLocation(code, row.getString("name"))
            row.strings("prefixes").forEach { prefixes[it] = code }
            row.strings("names").forEach { names.getOrPut(it) { mutableSetOf() }.add(code) }
        }
        namePattern = Regex("(^|[^\\p{L}\\p{N}])(" + names.keys.sortedByDescending { it.length }.joinToString("|", transform = Regex::escape) + ")(?=$|[^\\p{L}\\p{N}])", RegexOption.IGNORE_CASE)
    }
    /** An ISO country code, such as the exit country a trace reports. */
    fun fromCode(code: String): ServerLocation? = locations[code]
    fun fromName(name: String): ServerLocation? = codes(name).singleOrNull()?.let(locations::get)
    /** A Russian label anywhere, a chain's entry included. */
    fun russianEntry(name: String) = "RU" in codes(name)
    private fun codes(name: String): Set<String> {
        val codes = mutableSetOf<String>()
        flags.findAll(name).forEach { flag ->
            val code = flag.value.codePoints().toArray().map { (it - 0x1f1e6 + 'A'.code).toChar() }.joinToString("")
            if (code in locations) codes.add(code)
        }
        namePattern.findAll(places.replace(name) { it.groupValues[1] + " " }).forEach { names[it.groupValues[2].lowercase(Locale.ROOT)]?.let(codes::addAll) }
        prefix.find(name.trim())?.groupValues?.get(1)?.let { prefixes[it] }?.let(codes::add)
        // The EU flag often accompanies a member country, which is more specific.
        if (codes.size > 1) codes.remove("EU")
        return codes
    }
    // The desktop's flag images, exported by scripts/export-android-flags.
    fun flagImage(code: String): ImageBitmap? = flagImages.getOrPut(code) {
        runCatching { assets.open("flags/$code.webp").use(BitmapFactory::decodeStream)?.asImageBitmap() }.getOrNull()
    }
    fun displayName(name: String): String = fromName(name)?.let { flags.replace(name, "").trim().ifEmpty { it.name } } ?: name
}
