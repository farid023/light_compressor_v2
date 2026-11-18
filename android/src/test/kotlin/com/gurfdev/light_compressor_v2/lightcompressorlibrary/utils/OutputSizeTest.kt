package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import org.junit.Assert.assertEquals
import org.junit.Test

class OutputSizeTest {

    private val anySize: (Int, Int) -> Boolean = { _, _ -> true }

    @Test
    fun keeps1080WhenTheEncoderTakesIt() {
        assertEquals(Pair(1920, 1080), alignOutputSize(1920.0, 1080.0, 2, 2, anySize))
    }

    @Test
    fun keepsAScaledSizeWithoutStretching() {
        assertEquals(Pair(1440, 810), alignOutputSize(1440.0, 810.0, 2, 2, anySize))
    }

    @Test
    fun roundsToTheEncodersAlignment() {
        assertEquals(Pair(1282, 722), alignOutputSize(1281.0, 721.0, 2, 2, anySize))
        assertEquals(Pair(1920, 1088), alignOutputSize(1920.0, 1080.0, 16, 16, anySize))
    }

    @Test
    fun treatsAnAlignmentBelowTwoAsTwo() {
        assertEquals(Pair(1282, 722), alignOutputSize(1281.0, 721.0, 1, 1, anySize))
    }

    @Test
    fun fallsBackToMultiplesOf16WhenTheEncoderRejectsTheSize() {
        val only16: (Int, Int) -> Boolean = { w, h -> w % 16 == 0 && h % 16 == 0 }
        assertEquals(Pair(1920, 1088), alignOutputSize(1920.0, 1080.0, 2, 2, only16))
    }

    @Test
    fun neverReturnsZero() {
        assertEquals(Pair(2, 2), alignOutputSize(0.4, 0.4, 2, 2, anySize))
    }
}
