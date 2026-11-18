package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import kotlin.math.roundToInt

fun uInt32ToLong(int32: Int): Long {
    return int32.toLong()
}

fun uInt32ToInt(uInt32: Long): Int {
    if (uInt32 > Int.MAX_VALUE || uInt32 < 0) {
        throw Exception("uInt32 value is too large")
    }
    return uInt32.toInt()
}

fun uInt64ToLong(uInt64: Long): Long {
    if (uInt64 < 0) throw Exception("uInt64 value is too large")
    return uInt64
}


fun uInt32ToInt(uInt32: Int): Int {
    if (uInt32 < 0) {
        throw Exception("uInt32 value is too large")
    }
    return uInt32
}

private fun roundEven(value: Int): Int = value + 1 and 1.inv()

fun roundDimension(value: Double): Int =
    roundEven(((value / 16).roundToInt() * 16))

/**
 * Rounds a target size to one the encoder takes, without distorting the
 * picture: each side goes to the nearest multiple of the encoder's own
 * alignment (at least 2, since 4:2:0 needs even sides). Only when the encoder
 * rejects that size does it fall back to multiples of 16, which every encoder
 * takes — at the cost of a slight stretch (1080 becomes 1088).
 */
fun alignOutputSize(
    width: Double,
    height: Double,
    widthAlignment: Int,
    heightAlignment: Int,
    isSupported: (Int, Int) -> Boolean,
): Pair<Int, Int> {
    val aligned = Pair(
        alignTo(width, widthAlignment.coerceAtLeast(2)),
        alignTo(height, heightAlignment.coerceAtLeast(2)),
    )
    if (isSupported(aligned.first, aligned.second)) return aligned
    return Pair(roundDimension(width), roundDimension(height))
}

private fun alignTo(value: Double, alignment: Int): Int =
    ((value / alignment).roundToInt() * alignment).coerceAtLeast(alignment)
