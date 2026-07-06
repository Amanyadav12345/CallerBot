package com.callerbot.caller_bot

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * Fan-out point between the InCallService (telecom thread) and the Flutter
 * EventChannel (must be touched on the main thread).
 */
object CallEventBridge : EventChannel.StreamHandler {

    private var sink: EventChannel.EventSink? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun emitState(state: String, direction: String) {
        mainHandler.post {
            sink?.success(mapOf("state" to state, "direction" to direction))
        }
    }
}