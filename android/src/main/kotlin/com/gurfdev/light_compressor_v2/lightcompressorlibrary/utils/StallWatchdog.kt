package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

/** Thrown when a codec loop has made no progress for too long. */
class CodecStallException(message: String) : RuntimeException(message)

/**
 * Fails a codec loop that has stopped making progress. A codec that never
 * delivers its next buffer or its end of stream would otherwise spin the loop
 * forever, and the caller's Future would never complete. Call [progressed]
 * whenever a buffer comes out, and [check] on every turn of the loop.
 */
class StallWatchdog(
    private val timeoutMs: Long,
    private val nowMs: () -> Long = { System.nanoTime() / 1_000_000 },
) {
    private var lastProgressMs = nowMs()

    fun progressed() {
        lastProgressMs = nowMs()
    }

    /** Throws [CodecStallException] once [timeoutMs] passed without progress. */
    fun check(stage: String) {
        val idleMs = nowMs() - lastProgressMs
        if (idleMs > timeoutMs) {
            throw CodecStallException("The $stage made no progress for ${idleMs / 1000} s.")
        }
    }
}
