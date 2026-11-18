package com.gurfdev.light_compressor_v2.lightcompressorlibrary.utils

import android.media.MediaCodec

/**
 * A readable failure message for the caller. Codec failures often carry no
 * message at all (an IllegalStateException from MediaCodec.start(), for one),
 * which used to reach Dart as a bare "An error has occurred!". Falls back to
 * the exception's name and its cause, and adds the codec's own error code.
 *
 * Dart classifies an unclassified failure by words in its message ("codec",
 * "format", "track" make it an UnsupportedVideoException), so nothing added
 * here may contain such a word, or a returned OnFailure would start throwing.
 */
fun describeFailure(t: Throwable): String {
    val message = t.message?.takeIf { it.isNotBlank() }
    if (t is MediaCodec.CodecException) {
        // Not its class name, which contains "Codec"; the error code says more.
        return if (message != null) "$message (error ${t.errorCode})" else "Error ${t.errorCode}"
    }
    return when {
        message != null -> message
        t.cause != null && t.cause !== t -> "${t.javaClass.simpleName}: ${describeFailure(t.cause!!)}"
        else -> t.javaClass.simpleName
    }
}
