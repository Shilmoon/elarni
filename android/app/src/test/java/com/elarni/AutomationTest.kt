package com.elarni

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AutomationTest {
    private fun ready() = Automation(JSONObject()).apply { intent = true; online = true }

    @Test fun lowestLatencySwitchesOnlyForAClearGain() {
        val automation = ready()
        val order = listOf("current", "other")
        fun choose(current: Double, other: Double, time: Double = 1000.0) =
            automation.choose("lowestLatency", order, "current", mapOf("current" to current, "other" to other), healthy = true, time = time)
        assertEquals("other", choose(200.0, 100.0))
        assertEquals("Under 20 ms is noise", "current", choose(100.0, 85.0))
        assertEquals("Under 20 % is noise", "current", choose(1000.0, 850.0))
        assertEquals("A tie keeps the server", "current", choose(100.0, 100.0))
        automation.lastSwitch = 950.0
        assertEquals("No switch within 60 s of the last one", "current", choose(200.0, 100.0))
        assertEquals("other", choose(200.0, 100.0, time = 1010.0))
    }

    @Test fun lowestLatencyLeavesAFailingServerAndKeepsAnUnscoredHealthyOne() {
        val automation = ready()
        val order = listOf("current", "slow")
        assertEquals("slow", automation.choose("lowestLatency", order, "current", mapOf("current" to 10.0, "slow" to 900.0), healthy = false, time = 0.0))
        assertEquals("current", automation.choose("lowestLatency", order, "current", mapOf("slow" to 5.0), healthy = true, time = 1000.0))
        assertNull(automation.choose("lowestLatency", order, "current", emptyMap(), healthy = false, time = 0.0))
    }

    @Test fun orderedFallbackTakesTheFirstPassingBackup() {
        val automation = ready()
        val order = listOf("a", "b", "c")
        assertEquals("a", automation.choose("orderedFallback", order, "a", mapOf("a" to 50.0, "b" to 10.0), healthy = true, time = 0.0))
        assertEquals("b", automation.choose("orderedFallback", order, "a", mapOf("a" to 50.0, "b" to 10.0, "c" to 5.0), healthy = false, time = 0.0))
        assertEquals("A backup that failed its probe has no score", "c", automation.choose("orderedFallback", order, "a", mapOf("c" to 5.0), healthy = false, time = 0.0))
        assertEquals("a", automation.choose("fixed", order, "a", mapOf("a" to 50.0), healthy = true, time = 0.0))
        assertNull(automation.choose("fixed", order, "a", mapOf("a" to 50.0, "b" to 1.0), healthy = false, time = 0.0))
    }

    @Test fun roundsSkipCoolingServersAndRotateThroughTheRest() {
        val automation = ready()
        val others = (1..12).map { "s$it" }
        val first = automation.round(listOf("current") + others, "current", 0.0)
        assertEquals(10, first.size)
        assertEquals("current", first.first())
        val second = automation.round(listOf("current") + others, "current", 0.0)
        assertEquals("current", second.first())
        assertEquals("Two rounds probe every backup", others.toSet(), (first + second).toSet() - "current")

        automation.cooldown["s1"] = 60.0
        automation.cooldown["s2"] = 90.0
        assertFalse(automation.round(listOf("current", "s1", "s2", "s3"), "current", 59.0).any { it in listOf("s1", "s2") })
        assertTrue("A cooldown ends at its time", "s1" in automation.round(listOf("current", "s1", "s2", "s3"), "current", 60.0))
    }

    @Test fun retriesBackOffThenExhaustTheEpisode() {
        val automation = ready()
        val retries = mutableListOf<Double>()
        var time = 0.0
        while (true) {
            automation.schedule(time)
            if (automation.exhausted) break
            assertEquals("retrying", automation.status)
            assertFalse("A retry waits for its time", automation.begin(automation.retryAt!! - 0.5))
            time = automation.retryAt!!
            retries.add(time)
            assertTrue(automation.begin(time))
        }
        assertEquals(listOf(1.0, 3.0, 7.0, 15.0, 31.0, 61.0), retries)
        assertEquals(6, automation.attempts)
        assertEquals("exhausted", automation.status)
        assertNull(automation.healthAt)
    }

    @Test fun anEpisodeEndsAfterTwoMinutes() {
        val automation = ready()
        automation.schedule(0.0)
        assertTrue(automation.begin(100.0))
        automation.schedule(100.0)
        assertTrue(automation.begin(automation.retryAt!!))
        automation.schedule(118.0)
        assertTrue("A retry past 120 s ends the episode", automation.exhausted)
    }

    @Test fun nothingRetriesOfflineAsleepOrWithoutIntent() {
        for (setup in listOf<Automation.() -> Unit>({ online = false }, { sleeping = true }, { intent = false })) {
            val automation = ready().apply(setup)
            automation.schedule(0.0)
            assertNull(automation.retryAt)
            assertFalse(automation.begin(10.0))
        }
        val healthy = ready()
        healthy.schedule(0.0); healthy.begin(1.0); healthy.healthy(5.0)
        assertEquals(0, healthy.attempts)
        assertEquals(5.0 + Automation.healthInterval, healthy.healthAt!!, 0.0)
    }

    @Test fun healthCheckWaitsForTrafficAfterAPass() {
        val automation = ready().apply { healthy(0.0) }
        var reads = 0
        assertFalse("Not due yet", automation.healthDue(Automation.healthInterval - 1, passed = true) { reads++; true })
        assertEquals("The counter is read only when a check is due", 0, reads)
        val due = Automation.healthInterval + 1
        assertFalse("A passing server that carried nothing since is not probed", automation.healthDue(due, passed = true) { reads++; false })
        assertEquals(1, reads)
        assertEquals("The next look is one interval later", due + Automation.healthInterval, automation.healthAt!!, 0.0)
        assertTrue("Traffic left since the pass", automation.healthDue(due + Automation.healthInterval, passed = true) { true })
        assertTrue("The last check failed", automation.healthDue(due + Automation.healthInterval, passed = false) { reads++; false })
        assertEquals("A failed check is repeated without reading the counter", 1, reads)
        automation.failures = 1
        assertTrue("A health failure is checked again", automation.healthDue(due + Automation.healthInterval, passed = true) { false })
    }

    @Test fun unattendedRecoveryWaitsLongerEachTime() {
        val automation = Automation(obj("exhausted" to true)).apply { intent = true; online = true }
        var time = 0.0
        val waits = mutableListOf<Double>()
        repeat(4) {
            val start = time
            automation.unattended(time)
            while (automation.exhausted) { time += 1.0; automation.unattended(time) }
            waits.add(time - start)
            automation.exhausted = true
        }
        assertEquals("Past TSPU's ~120 s SNI freeze, then longer", listOf(150.0, 300.0, 600.0, 600.0), waits)

        val offline = Automation(obj("exhausted" to true)).apply { intent = true; online = true }
        offline.unattended(0.0)
        offline.online = false; offline.unattended(100.0)
        offline.online = true; offline.unattended(149.0); offline.unattended(160.0)
        assertTrue("Going offline restarts the wait", offline.exhausted)
        offline.unattended(299.0)
        assertFalse(offline.exhausted)
    }

    @Test fun anInterruptedEpisodeStaysExhaustedAfterARestart() {
        assertFalse(Automation(JSONObject()).exhausted)
        assertTrue(Automation(obj("attempts" to 2)).exhausted)
        assertTrue(Automation(obj("interrupted" to true)).exhausted)
        val running = ready()
        running.schedule(0.0)
        assertTrue(Automation(running.episode()).exhausted)
    }

    @Test fun recoveryPrefersRussianEntriesInWhitelistModeThenTcp443() {
        val automation = ready()
        val order = listOf("a", "b", "c", "d")
        assertEquals(listOf("c", "a", "b", "d"), automation.recoveryOrder(order, "a", tcp443 = setOf("c"), russianEntry = setOf("d")))
        assertEquals("A failing TCP 443 server keeps the user's order", order, automation.recoveryOrder(order, "c", tcp443 = setOf("c"), russianEntry = setOf("d")))
        automation.observe("a", passed = false, russianEntry = false)
        assertFalse(automation.whitelist)
        automation.observe("b", passed = false, russianEntry = false)
        automation.observe("d", passed = true, russianEntry = true)
        assertTrue(automation.whitelist)
        assertEquals(listOf("d", "c", "a", "b"), automation.recoveryOrder(order, "a", tcp443 = setOf("c"), russianEntry = setOf("d")))
        automation.observe("b", passed = true, russianEntry = false)
        assertFalse("A foreign pass ends whitelist mode", automation.whitelist)
    }

    @Test fun tcp443RecognizesOnlyTlsLikeTcpOnPort443() {
        fun config(protocol: String, port: Int, network: String = "tcp", alpn: List<String>? = null) = obj("outbounds" to JSONArray(listOf(obj(
            "protocol" to protocol, "settings" to obj("vnext" to JSONArray(listOf(obj("address" to "example.com", "port" to port)))),
            "streamSettings" to obj("network" to network, "tlsSettings" to obj("alpn" to alpn?.let { JSONArray(it) }))))))
        assertTrue(Automation.tcp443(config("vless", 443)))
        assertFalse(Automation.tcp443(config("vless", 8443)))
        assertFalse(Automation.tcp443(config("hysteria", 443)))
        assertFalse(Automation.tcp443(config("vless", 443, network = "kcp")))
        assertFalse(Automation.tcp443(config("vless", 443, alpn = listOf("h3"))))
        assertTrue(Automation.tcp443(obj("outbounds" to JSONArray(listOf(obj("protocol" to "shadowsocks", "settings" to obj("servers" to JSONArray(listOf(obj("port" to 443))))))))))
        assertFalse("A malformed config is not TCP 443", Automation.tcp443(JSONObject()))
    }

    @Test fun validateAcceptsAWorkingConfigurationAndRefusesUnsafeOnes() {
        val catalog = Catalog(obj("selectedNodeId" to "a", "subscriptions" to JSONArray(listOf(obj("id" to "s", "nodes" to JSONArray(listOf(
            obj("id" to "a", "format" to "xrayProfile"), obj("id" to "b", "format" to "xrayProfile"), obj("id" to "t", "format" to "telegram"))))))))
        fun target(url: String, id: String = "check", status: Int = 204) = obj("id" to id, "url" to url, "expectedStatus" to status, "expectedBody" to "")
        fun config(vararg changes: Pair<String, Any?>) = obj("schemaVersion" to 1, "enabled" to true, "policy" to "lowestLatency", "subscriptionID" to "s",
            "nodeIDs" to JSONArray(listOf("a", "b")), "targets" to JSONArray(listOf(target("https://www.gstatic.com/generate_204")))).apply { changes.forEach { (key, value) -> put(key, value) } }
        Automation.validate(config(), catalog)
        Automation.validate(Automation.defaults(), catalog)
        // Alone, the second spelling of the host below is valid, so its refusal is about the duplicate.
        Automation.validate(config("targets" to JSONArray(listOf(target("https://WWW.gstatic.com./b")))), catalog)
        val refused = mapOf(
            "unknown policy" to config("policy" to "random"),
            "three targets" to config("targets" to JSONArray((1..3).map { target("https://h$it.example/", "t$it") })),
            "one host twice" to config("targets" to JSONArray(listOf(target("https://www.gstatic.com/a", "one"), target("https://WWW.gstatic.com./b", "two")))),
            "credentials in the URL" to config("targets" to JSONArray(listOf(target("https://user:pass@example.com/")))),
            "a script URL" to config("targets" to JSONArray(listOf(target("javascript:alert(1)")))),
            "a failing status" to config("targets" to JSONArray(listOf(target("https://example.com/", status = 404)))),
            "selected server missing" to config("nodeIDs" to JSONArray(listOf("b"))),
            "a Telegram proxy" to config("nodeIDs" to JSONArray(listOf("a", "t"))),
            "a duplicate server" to config("nodeIDs" to JSONArray(listOf("a", "a"))),
            "a Russian entry outside the list" to config("russianEntryNodeIDs" to JSONArray(listOf("t"))),
            "no targets" to config("targets" to JSONArray()))
        for ((reason, value) in refused) {
            val error = runCatching { Automation.validate(value, catalog) }.exceptionOrNull()
            assertEquals(reason, "invalid_automation", (error as? AppFailure)?.code)
        }
    }
}
