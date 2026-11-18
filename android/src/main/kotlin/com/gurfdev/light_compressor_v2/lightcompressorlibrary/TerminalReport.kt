package com.gurfdev.light_compressor_v2.lightcompressorlibrary

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Job

/**
 * Makes sure one video gets exactly one terminal callback (success, failure or
 * cancelled). A batch replies only when every slot has a result, so a video
 * that never reports hangs the whole batch.
 */
internal class TerminalReport {
    private val reported = AtomicBoolean(false)

    /** Runs [action] only if nothing was reported yet; true when it ran. */
    fun once(action: () -> Unit): Boolean {
        if (!reported.compareAndSet(false, true)) return false
        action()
        return true
    }
}

/**
 * Reports through [onUnreported] when this job completes without a terminal
 * report — with its cancellation cause, or null when the body just ended. A
 * coroutine cancelled before it is dispatched never runs its body at all, so
 * the body's own try/catch cannot be relied on to report a cancel.
 */
internal fun Job.reportIfUnreported(report: TerminalReport, onUnreported: (Throwable?) -> Unit): Job {
    invokeOnCompletion { cause -> report.once { onUnreported(cause) } }
    return this
}
