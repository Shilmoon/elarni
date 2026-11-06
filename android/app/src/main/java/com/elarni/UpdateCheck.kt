package com.elarni

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject

/** The update notice: reads the feed the user set once a day, or hourly while it cannot be read. Nothing installs. */
object UpdateCheck {
    /** Instrumentation replaces the network. The app's own sockets bypass its VPN, so a connected fetch goes through the core. */
    @Volatile var fetch: (String) -> String = { url ->
        Native.cancellable("fetchSubscription", obj("url" to url, "proxy" to (Engine.fetchProxy ?: JSONObject.NULL))).getString("body")
    }
    /** Release builds read Elarni's releases until the user changes or clears the feed; debug builds start with it off. */
    const val ELARNI_RELEASES = "https://api.github.com/repos/Shilmoon/elarni/releases/latest"
    /** A newer release's version and page. */
    val available = MutableStateFlow<Pair<String, String>?>(null)
    private var checked: Triple<String, Long, Boolean>? = null
    private val lock = Mutex()

    // A debug build's name ends in -dev, which marks the build type, not a pre-release.
    suspend fun refresh(feed: String, version: String = BuildConfig.VERSION_NAME.substringBefore('-')) = lock.withLock {
        if (feed.isEmpty()) { checked = null; available.value = null; return@withLock }
        val now = System.currentTimeMillis()
        checked?.let { (url, at, read) -> if (url == feed && now - at < if (read) 86_400_000 else 3_600_000) return@withLock }
        val release = withContext(Dispatchers.IO) { runCatching { parse(fetch(feed)) }.getOrNull() }
        checked = Triple(feed, now, release != null)
        available.value = release?.takeIf { (compare(it.first, version) ?: 0) > 0 }
    }

    /** Elarni's own {"version", "url"} or a GitHub releases/latest reply, whose own url is its API address. */
    fun parse(body: String): Pair<String, String>? = runCatching {
        val value = JSONObject(body)
        val github = value.has("tag_name")
        val version = value.opt(if (github) "tag_name" else "version") as? String ?: return null
        val url = value.opt(if (github) "html_url" else "url") as? String ?: return null
        if (compare(version, "0") == null || !isHttps(url)) null else version.removePrefix("v").removePrefix("V") to url
    }.getOrNull()

    fun isHttps(url: String) = url.startsWith("https://") && url.length <= 2048 && Catalog.safeURL(url) != null

    /** Dotted numbers, an optional leading v and an ignored +build; anything else (a pre-release tag) is null. */
    fun compare(a: String, b: String): Int? {
        fun parts(value: String) = Regex("^[vV]?(\\d{1,9}(?:\\.\\d{1,9})*)(?:\\+.*)?$").matchEntire(value)?.groupValues?.get(1)?.split('.')?.map(String::toInt)
        val left = parts(a) ?: return null
        val right = parts(b) ?: return null
        for (i in 0 until maxOf(left.size, right.size)) {
            val difference = left.getOrElse(i) { 0 } - right.getOrElse(i) { 0 }
            if (difference != 0) return difference
        }
        return 0
    }
}
