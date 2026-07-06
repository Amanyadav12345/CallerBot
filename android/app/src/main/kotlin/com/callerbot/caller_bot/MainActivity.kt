package com.callerbot.caller_bot

import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.telecom.TelecomManager
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Places calls through the phone's own dialer over the mobile SIM using
 * `ACTION_CALL`, and reports the call lifecycle back to Flutter by listening to
 * the system telephony state (READ_PHONE_STATE). No default-dialer role is
 * required.
 */
class MainActivity : FlutterActivity() {

    private val methodChannelName = "caller_bot/telephony"
    private val eventChannelName = "caller_bot/call_events"

    private var telephonyManager: TelephonyManager? = null
    private var legacyListener: PhoneStateListener? = null
    private var telephonyCallback: TelephonyCallback? = null

    // Tracks whether a call we placed is currently up, so an IDLE that arrives
    // before we ever dialled isn't reported as a disconnect.
    private var callInProgress = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(CallEventBridge)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Kept for API compatibility with the Dart side; the app no
                    // longer needs to be the default dialer.
                    "isDefaultDialer" -> result.success(false)
                    "requestDefaultDialer" -> result.success(false)
                    "placeCall" -> {
                        val number = call.argument<String>("number")
                        if (number.isNullOrBlank()) {
                            result.error("BAD_ARG", "number is required", null)
                        } else {
                            placeCall(number)
                            result.success(null)
                        }
                    }
                    "endCall" -> {
                        result.success(endCall())
                    }
                    "answerCall" -> result.success(null)
                    "rejectCall" -> result.success(null)
                    "runRoot" -> {
                        val script = call.argument<String>("script") ?: ""
                        runRootAsync(script, result)
                    }
                    "setSpeaker" -> {
                        setSpeaker(call.argument<Boolean>("on") ?: true)
                        result.success(null)
                    }
                    "maxMediaVolume" -> {
                        // The message plays on the media (music) stream out of
                        // the loudspeaker; maxing it makes the acoustic coupling
                        // into the call mic as strong as possible.
                        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
                        am.setStreamVolume(
                            AudioManager.STREAM_MUSIC,
                            am.getStreamMaxVolume(AudioManager.STREAM_MUSIC),
                            0
                        )
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        registerPhoneStateListener()
    }

    /** Dial through the system dialer on the default outgoing SIM. */
    private fun placeCall(number: String) {
        callInProgress = true
        val intent = Intent(Intent.ACTION_CALL, Uri.fromParts("tel", number, null))
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    /**
     * Best-effort programmatic hangup. Works when ANSWER_PHONE_CALLS is granted
     * (API 28+); otherwise there is no way to end a call from a non-default
     * dialer, so this is a no-op and the user hangs up manually.
     */
    @Suppress("MissingPermission")
    private fun endCall(): Boolean {
        return try {
            val telecom = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                telecom.endCall()
            } else {
                false
            }
        } catch (e: SecurityException) {
            false
        } catch (e: Exception) {
            false
        }
    }

    /**
     * Runs a shell [script] as root (via `su`) on a background thread and
     * returns {exitCode, output}. All commands run in a single su session so
     * Magisk only prompts once.
     */
    private fun runRootAsync(script: String, result: MethodChannel.Result) {
        Thread {
            val res = runRootBlocking(script)
            runOnUiThread { result.success(res) }
        }.start()
    }

    private fun runRootBlocking(script: String): Map<String, Any> {
        return try {
            val process = ProcessBuilder("su")
                .redirectErrorStream(true)
                .start()
            process.outputStream.bufferedWriter().use { writer ->
                writer.write(script)
                writer.write("\nexit\n")
                writer.flush()
            }
            val output = process.inputStream.bufferedReader().readText()
            val code = process.waitFor()
            mapOf("exitCode" to code, "output" to output)
        } catch (e: Exception) {
            mapOf("exitCode" to -1, "output" to "ERROR: ${e.message}")
        }
    }

    private fun setSpeaker(on: Boolean) {
        val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
        @Suppress("DEPRECATION")
        am.isSpeakerphoneOn = on
    }

    private fun registerPhoneStateListener() {
        val tm = getSystemService(Context.TELEPHONY_SERVICE) as TelephonyManager
        telephonyManager = tm
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = handleCallState(state)
            }
            telephonyCallback = cb
            tm.registerTelephonyCallback(mainExecutor, cb)
        } else {
            val listener = object : PhoneStateListener() {
                @Deprecated("Deprecated in Java")
                override fun onCallStateChanged(state: Int, phoneNumber: String?) =
                    handleCallState(state)
            }
            legacyListener = listener
            @Suppress("DEPRECATION")
            tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
        }
    }

    private fun handleCallState(state: Int) {
        when (state) {
            TelephonyManager.CALL_STATE_OFFHOOK -> {
                // Line is in use — the call we placed has been dialled. This is
                // the earliest signal available without being the default
                // dialer; it fires at dial time, not on answer.
                CallEventBridge.emitState("offhook", "outgoing")
            }
            TelephonyManager.CALL_STATE_IDLE -> {
                if (callInProgress) {
                    callInProgress = false
                    CallEventBridge.emitState("idle", "outgoing")
                }
            }
            TelephonyManager.CALL_STATE_RINGING -> {
                CallEventBridge.emitState("ringing", "incoming")
            }
        }
    }

    override fun onDestroy() {
        val tm = telephonyManager
        if (tm != null) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                telephonyCallback?.let { tm.unregisterTelephonyCallback(it) }
            } else {
                @Suppress("DEPRECATION")
                legacyListener?.let { tm.listen(it, PhoneStateListener.LISTEN_NONE) }
            }
        }
        telephonyCallback = null
        legacyListener = null
        telephonyManager = null
        super.onDestroy()
    }
}
