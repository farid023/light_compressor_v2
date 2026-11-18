package com.gurfdev.light_compressor_v2.lightcompressorlibrary

import java.util.ArrayDeque
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class TerminalReportTest {

    /** Queues dispatched coroutines until the test runs them. */
    private class ManualDispatcher : CoroutineDispatcher() {
        val queue = ArrayDeque<Runnable>()
        override fun dispatch(context: CoroutineContext, block: Runnable) {
            queue.add(block)
        }
        fun runAll() {
            while (queue.isNotEmpty()) queue.removeFirst().run()
        }
    }

    @Test
    fun aJobCancelledBeforeItRunsStillReports() {
        val dispatcher = ManualDispatcher()
        val report = TerminalReport()
        var bodyRan = false
        val unreported = mutableListOf<Throwable?>()

        val job = CoroutineScope(Job()).launch(dispatcher) {
            bodyRan = true
            report.once { }
        }.reportIfUnreported(report) { cause -> unreported += cause }
        job.cancel()
        dispatcher.runAll()

        // The body — and any try/catch inside it — never ran.
        assertFalse(bodyRan)
        assertEquals(1, unreported.size)
        assertTrue(unreported[0] is CancellationException)
    }

    @Test
    fun aBodyThatEndsWithoutReportingIsCaught() {
        val dispatcher = ManualDispatcher()
        val unreported = mutableListOf<Throwable?>()

        CoroutineScope(Job()).launch(dispatcher) { }
            .reportIfUnreported(TerminalReport()) { cause -> unreported += cause }
        dispatcher.runAll()

        assertEquals(1, unreported.size)
        assertNull(unreported[0])
    }

    @Test
    fun aReportedJobIsNotReportedAgain() {
        val dispatcher = ManualDispatcher()
        val report = TerminalReport()
        var reports = 0

        CoroutineScope(Job()).launch(dispatcher) { report.once { reports++ } }
            .reportIfUnreported(report) { reports++ }
        dispatcher.runAll()

        assertEquals(1, reports)
    }

    @Test
    fun onceRunsOnlyTheFirstAction() {
        val report = TerminalReport()
        assertTrue(report.once { })
        assertFalse(report.once { throw AssertionError("must not run") })
    }
}
