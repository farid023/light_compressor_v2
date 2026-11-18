package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.fail
import org.junit.Test

class StallWatchdogTest {

    private var nowMs = 0L
    private val watchdog = StallWatchdog(timeoutMs = 30_000) { nowMs }

    @Test
    fun staysQuietWithinTheTimeout() {
        nowMs = 30_000
        watchdog.check("video transcode")
    }

    @Test
    fun failsOnceTheTimeoutPasses() {
        nowMs = 30_001
        try {
            watchdog.check("video transcode")
            fail("expected a stall")
        } catch (e: CodecStallException) {
            assertEquals("The video transcode made no progress for 30 s.", e.message)
        }
    }

    @Test
    fun progressRestartsTheClock() {
        nowMs = 25_000
        watchdog.progressed()
        nowMs = 50_000
        watchdog.check("video transcode")
    }
}
