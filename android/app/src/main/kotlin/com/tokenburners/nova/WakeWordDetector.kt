package com.tokenburners.nova

/**
 * Pluggable wake-word backend. The foreground service owns the single mic
 * stream and hands every 16 kHz mono PCM16 frame to [accept]; an implementation
 * returns true on the frame that completes the wake phrase ("Wake Up").
 *
 * [NoopWakeWordDetector] is the default — it never fires, so on-device the
 * pipeline is driven by `simulateWake` until a real backend (openWakeWord /
 * Porcupine) is dropped in here.
 */
interface WakeWordDetector {
    /** @param frame PCM16 samples, mono, 16 kHz. @return true = wake phrase detected. */
    fun accept(frame: ShortArray): Boolean

    fun reset() {}

    fun release() {}
}

class NoopWakeWordDetector : WakeWordDetector {
    override fun accept(frame: ShortArray): Boolean = false
}
