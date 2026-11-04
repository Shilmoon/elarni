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

    @Test fun probeKeyNamesTheHandshakeSNI() {
        fun node(security: String, serverName: String? = null, address: String = "1.2.3.4") = obj("config" to obj("outbounds" to JSONArray(listOf(obj(
            "protocol" to "vless", "settings" to obj("vnext" to JSONArray(listOf(obj("address" to address, "port" to 443)))),
            "streamSettings" to obj("security" to security, "realitySettings" to serverName?.let { obj("serverName" to it) }))))))
        assertEquals("www.example.com", Catalog.probeKey(node("reality", "WWW.Example.com")))
        assertEquals("TLS without a name sends the address", "edge.example", Catalog.probeKey(node("tls", address = "Edge.Example")))
        assertNull("A plain server sends no SNI", Catalog.probeKey(node("none")))
    }

    @Test fun retryDelayAndCanonicalForm() {
        assertEquals(listOf(60, 60, 300, 1800, 1800), listOf(0, 1, 2, 3, 9).map(Catalog::retryDelay))
        assertEquals(Catalog.canonical(JSONObject("""{"b":[1,{"y":2,"x":"s"}],"a":null}""")), Catalog.canonical(JSONObject("""{"a":null,"b":[1,{"x":"s","y":2}]}""")))
        assertNotEquals(Catalog.canonical(JSONArray("[1,2]")), Catalog.canonical(JSONArray("[2,1]")))
    }
}
