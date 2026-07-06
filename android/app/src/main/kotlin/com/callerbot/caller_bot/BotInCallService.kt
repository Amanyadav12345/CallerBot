package com.callerbot.caller_bot

import android.telecom.Call
import android.telecom.CallAudioState
import android.telecom.InCallService

/**
 * Bound by the Telecom framework while this app holds the default-dialer role.
 * Gives us the one thing normal apps never get: the real state of the call
 * (dialing vs. answered) and the power to disconnect it.
 */
class BotInCallService : InCallService() {

    companion object {
        var instance: BotInCallService? = null
            private set
        var currentCall: Call? = null
            private set

        fun hangup() {
            currentCall?.disconnect()
        }

        fun setSpeaker(on: Boolean) {
            instance?.setAudioRoute(
                if (on) CallAudioState.ROUTE_SPEAKER else CallAudioState.ROUTE_EARPIECE
            )
        }

        fun answer() {
            currentCall?.answer(android.telecom.VideoProfile.STATE_AUDIO_ONLY)
        }

        fun reject() {
            currentCall?.reject(false, null)
        }
    }

    private val callback = object : Call.Callback() {
        override fun onStateChanged(call: Call, state: Int) {
            CallEventBridge.emitState(stateName(state), directionOf(call))
        }
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    override fun onDestroy() {
        instance = null
        super.onDestroy()
    }

    override fun onCallAdded(call: Call) {
        currentCall = call
        call.registerCallback(callback)
        CallEventBridge.emitState(stateName(callStateOf(call)), directionOf(call))
    }

    override fun onCallRemoved(call: Call) {
        call.unregisterCallback(callback)
        if (currentCall == call) currentCall = null
        CallEventBridge.emitState("disconnected", directionOf(call))
    }

    @Suppress("DEPRECATION")
    private fun callStateOf(call: Call): Int =
        if (android.os.Build.VERSION.SDK_INT >= 31) call.details.state else call.state

    private fun directionOf(call: Call): String =
        if (call.details.callDirection == Call.Details.DIRECTION_INCOMING) "incoming" else "outgoing"

    private fun stateName(state: Int): String = when (state) {
        Call.STATE_CONNECTING -> "connecting"
        Call.STATE_DIALING -> "dialing"
        Call.STATE_RINGING -> "ringing"
        Call.STATE_ACTIVE -> "active"
        Call.STATE_HOLDING -> "holding"
        Call.STATE_DISCONNECTING -> "disconnecting"
        Call.STATE_DISCONNECTED -> "disconnected"
        else -> "unknown"
    }
}