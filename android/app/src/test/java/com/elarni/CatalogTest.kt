package com.elarni

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class CatalogTest {
    private fun read(vararg headers: Pair<String, String>): Pair<JSONObject, JSONObject> {
        val metadata = JSONObject(); val links = JSONObject()
        Catalog.readHeaders(obj(*headers), metadata, links)
        return metadata to links
    }

    @Test fun subscriptionUserinfoKeepsOnlyUnambiguousCounters() {
        val (metadata, _) = read("subscription-userinfo" to "upload=1; download = 2;total=30000000000; expire=1700000000; plan=9")
        assertEquals(1L, metadata.getLong("upload"))
        assertEquals(2L, metadata.getLong("download"))
        assertEquals("Counters beyond 32 bits", 30000000000L, metadata.getLong("total"))
        assertEquals(1700000000L, metadata.getLong("expire"))
        assertFalse(metadata.has("plan"))
        val (odd, _) = read("subscription-userinfo" to "upload=5; upload=6; download=-1; total=many; expire=1=2")
        assertFalse("A repeated field is ambiguous", odd.has("upload"))
        assertFalse(odd.has("download"))
        assertFalse(odd.has("total"))
        assertFalse(odd.has("expire"))
        assertEquals(0, read().first.length())
    }

    @Test fun providerTextDropsControlCharactersAndBlanks() {
        val (metadata, _) = read("announce" to "  Maintenance\u0007 tonight\n ", "banner-text" to " \t ", "banner-button-text" to "Renew")
        assertEquals("Maintenance tonight", metadata.getString("announcement"))
        assertFalse(metadata.has("bannerText"))
        assertEquals("Renew", metadata.getString("bannerButtonText"))
        assertNull(Catalog.display("x".repeat(16385)))
        assertEquals("Plain title", Catalog.display(" Plain title "))
    }

    @Test fun providerLinksMustBePlainWebAddresses() {
        val (_, links) = read("support-url" to "https://support.example/help", "profile-web-page-url" to "javascript:alert(1)", "banner-button-url" to "https://a.example/old")
        assertEquals("https://support.example/help", links.getString("support"))
        assertFalse(links.has("account"))
        assertEquals("https://a.example/old", links.getString("banner"))
        assertEquals("https://b.example/premium", read("banner-button-url" to "https://a.example/old", "premium-url" to "https://b.example/premium").second.getString("banner"))
        for (unsafe in listOf("intent://scan/#Intent;scheme=zxing;end", "tg://resolve?domain=x", "file:///sdcard/a", "https://user:pass@example.com/", "https://example.com/#top", "https:///path", ""))
            assertFalse(unsafe, read("support-url" to unsafe).second.has("support"))
    }

    @Test fun flagsAndUpdateIntervalAcceptOnlyClearValues() {
        val (metadata, _) = read("routing-enable" to "0", "hide-settings" to "TRUE", "x-hwid-active" to "maybe", "profile-update-interval" to " 12 ")
        assertEquals(false, metadata.get("routingEnabled"))
        assertEquals(true, metadata.get("hideSettings"))
        assertFalse(metadata.has("deviceRegistered"))
        assertEquals(12, metadata.getInt("updateIntervalHours"))
        assertEquals("A week at most", 168, read("profile-update-interval" to "500").first.getInt("updateIntervalHours"))
        for (ignored in listOf("0", "1.5", "-3", "1234567", "twelve")) assertFalse(ignored, read("profile-update-interval" to ignored).first.has("updateIntervalHours"))
    }

    @Test fun safeURLAdmitsOnlyHttpAndHttpsWithAHost() {
        assertEquals("https://example.com/a?b=c", Catalog.safeURL("https://example.com/a?b=c"))
        assertEquals("http://127.0.0.1:8080/", Catalog.safeURL("http://127.0.0.1:8080/"))
        for (unsafe in listOf("", "ftp://example.com/", "javascript:alert(1)", "data:text/html,x", "https://", "https://u@example.com/",
            "https://example.com/#f", "https://example.com/\u0000", "https://example.com/ a", "https://example.com/" + "a".repeat(16384)))
            assertNull(unsafe.take(40), Catalog.safeURL(unsafe))
    }

    @Test fun elarniRoutingLinksWinOverOtherApps() {
        assertEquals(listOf("elarni://routing/add/b"), Catalog.addressedRouting(listOf("happ://routing/add/a", "elarni://routing/add/b")))
        assertEquals(listOf("happ://routing/add/a"), Catalog.addressedRouting(listOf("happ://routing/add/a")))
        assertTrue(Catalog.isRoutingLink("incy://routing/off"))
        assertFalse(Catalog.isRoutingLink("https://routing/"))
    }

    @Test fun onlyAPublishedCopyKeepsWhatItRead() {
        fun data() = obj("subscriptions" to JSONArray(listOf(obj("id" to "s", "nodes" to JSONArray(listOf(obj("id" to "a")))))))
        val working = Catalog(data()); val published = Catalog(data(), snapshot = true)
        working.putSource(obj("id" to "t", "nodes" to JSONArray(listOf(obj("id" to "b")))))
        assertEquals("An editor's copy shows each edit", listOf("a", "b"), working.nodes.map { it.getString("id") })
        assertEquals("b", working.node("b").getString("id"))
        assertSame("A published copy reads its servers once", published.nodes, published.nodes)
        assertEquals("a", published.node("a").getString("id"))
        assertNull(published.nodeOrNull("b"))
    }

    @Test fun probeKeyNamesTheHandshakeSNI() {
        fun node(security: String, serverName: String? = null, address: String = "1.2.3.4") = obj("config" to obj("outbounds" to JSONArray(listOf(obj(
            "protocol" to "vless", "settings" to obj("vnext" to JSONArray(listOf(obj("address" to address, "port" to 443)))),
            "streamSettings" to obj("security" to security, "realitySettings" to serverName?.let { obj("serverName" to it) }))))))
        assertEquals("www.example.com", Catalog.probeKey(node("reality", "WWW.Example.com")))
        assertEquals("TLS without a name sends the address", "edge.example", Catalog.probeKey(node("tls", address = "Edge.Example")))
        assertNull("A plain server sends no SNI", Catalog.probeKey(node("none")))
    }

    @Test fun perAppModesKeepAppsThatNeedNoTunnelOutOfIt() {
        val uids = mapOf("com.a" to 10001, "com.b" to 10002, "com.c" to 10003, "com.shared.one" to 10009, "com.shared.two" to 10009, "com.elarni" to 10000)
        fun apps(mode: String, listed: List<String>, targets: JSONObject = JSONObject()) =
            Catalog.tunnelApps(obj("perAppMode" to mode, "perAppProcesses" to JSONArray(listed), "perAppTargets" to targets), "com.elarni") { uids[it] }
        assertNull("Off: every app enters", apps("off", listOf("com.a")))
        assertEquals("Only listed: just the listed apps enter, whatever their target", true to listOf("com.a", "com.b"),
            apps("proxyOnly", listOf("com.a", "com.gone", "com.b", "com.elarni"), obj("com.b" to "direct")))
        assertNull("With no listed app installed, an allowed list would match no app", apps("proxyOnly", listOf("com.gone", "com.elarni")))
        assertEquals("Bypass: only apps going direct stay out", false to listOf("com.a", "com.b"),
            apps("bypass", listOf("com.a", "com.b", "com.c", "com.gone", "com.elarni"), obj("com.b" to "direct", "com.c" to "routing")))
        for (target in listOf("routing", "block", "node:server", "proxy:socks5://127.0.0.1:1080"))
            assertEquals("A $target target keeps its app in the tunnel", false to emptyList<String>(), apps("bypass", listOf("com.a"), obj("com.a" to target)))
        assertEquals("An app sharing a UID follows the target of an app listed with one", false to emptyList<String>(),
            apps("bypass", listOf("com.shared.one", "com.shared.two"), obj("com.shared.two" to "routing")))
        assertEquals("The first listed target wins for a shared UID", false to listOf("com.shared.one", "com.shared.two"),
            apps("bypass", listOf("com.shared.one", "com.shared.two"), obj("com.shared.one" to "direct", "com.shared.two" to "routing")))
    }

    @Test fun retryDelayAndCanonicalForm() {
        assertEquals(listOf(60, 60, 300, 1800, 1800), listOf(0, 1, 2, 3, 9).map(Catalog::retryDelay))
        assertEquals(Catalog.canonical(JSONObject("""{"b":[1,{"y":2,"x":"s"}],"a":null}""")), Catalog.canonical(JSONObject("""{"a":null,"b":[1,{"x":"s","y":2}]}""")))
        assertNotEquals(Catalog.canonical(JSONArray("[1,2]")), Catalog.canonical(JSONArray("[2,1]")))
    }
}
