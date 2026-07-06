package com.callerbot.caller_bot

import android.app.role.RoleManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.Uri
import android.telecom.TelecomManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val methodChannelName = "caller_bot/telephony"
    private val eventChannelName = "caller_bot/call_events"
    private val requestRoleCode = 4001
    private var pendingRoleResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, eventChannelName)
            .setStreamHandler(CallEventBridge)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, methodChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isDefaultDialer" -> result.success(isDefaultDialer())
                    "requestDefaultDialer" -> requestDefaultDialer(result)
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
                        BotInCallService.hangup()
                        result.success(null)
                    }
                    "answerCall" -> {
                        BotInCallService.answer()
                        result.success(null)
                    }
                    "rejectCall" -> {
                        BotInCallService.reject()
                        result.success(null)
                    }
                    "setSpeaker" -> {
                        BotInCallService.setSpeaker(call.argument<Boolean>("on") ?: true)
                        result.success(null)
                    }
                    "maxMediaVolume" -> {
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
    }

    private fun isDefaultDialer(): Boolean {
        val telecom = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        return telecom.defaultDialerPackage == packageName
    }

    private fun requestDefaultDialer(result: MethodChannel.Result) {
        if (isDefaultDialer()) {
            result.success(true)
            return
        }
        val roleManager = getSystemService(Context.ROLE_SERVICE) as RoleManager
        if (!roleManager.isRoleAvailable(RoleManager.ROLE_DIALER)) {
            result.success(false)
            return
        }
        pendingRoleResult = result
        startActivityForResult(
            roleManager.createRequestRoleIntent(RoleManager.ROLE_DIALER),
            requestRoleCode
        )
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == requestRoleCode) {
            pendingRoleResult?.success(isDefaultDialer())
            pendingRoleResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    private fun placeCall(number: String) {
        val telecom = getSystemService(Context.TELECOM_SERVICE) as TelecomManager
        val uri = Uri.fromParts("tel", number, null)
        telecom.placeCall(uri, null)
    }
}
