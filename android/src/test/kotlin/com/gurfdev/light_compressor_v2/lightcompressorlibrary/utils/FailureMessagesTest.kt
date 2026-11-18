package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import java.io.IOException
import org.junit.Assert.assertEquals
import org.junit.Test

class FailureMessagesTest {

    @Test
    fun keepsAnExistingMessage() {
        assertEquals("No video track", describeFailure(IllegalArgumentException("No video track")))
    }

    @Test
    fun namesTheExceptionWhenItHasNoMessage() {
        assertEquals("IllegalStateException", describeFailure(IllegalStateException()))
    }

    @Test
    fun treatsABlankMessageAsMissing() {
        assertEquals("IllegalStateException", describeFailure(IllegalStateException("  ")))
    }

    @Test
    fun addsTheCauseWhenTheExceptionHasNoMessage() {
        val failure = RuntimeException(null, IOException("disk full"))
        assertEquals("RuntimeException: disk full", describeFailure(failure))
    }
}
