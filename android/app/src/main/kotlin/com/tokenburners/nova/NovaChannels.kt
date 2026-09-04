package com.tokenburners.nova

/**
 * Method/event channel names shared between the Dart layer and the native
 * services. Kept in one place so both sides can't drift.
 */
object NovaChannels {
    /** Dart -> native commands (start/stop listener, overlay, status, app ops). */
    const val BRIDGE = "com.tokenburners.nova/bridge"

    /** Native -> Dart stream: wake-word hits and service lifecycle events. */
    const val EVENTS = "com.tokenburners.nova/events"

    /** Dart -> native: on-device speech-to-text (whisper.cpp). */
    const val STT = "com.tokenburners.nova/stt"

    /** Dart -> native: on-device LLM inference (llama.cpp). */
    const val LLM = "com.tokenburners.nova/llm"

    /** Dart -> native: generic Accessibility driver primitives. */
    const val A11Y = "com.tokenburners.nova/a11y"
}
