import 'package:flutter/services.dart';

/// A single call-state event derived from the system telephony state on the
/// Android side (see MainActivity.kt).
class CallEvent {
  final String state; // offhook, idle, ringing
  final String direction; // incoming | outgoing

  const CallEvent(this.state, this.direction);

  bool get isIncoming => direction == 'incoming';

  /// The call we placed is now up on the line (dialling/connected). This is the
  /// earliest signal available when using the native dialer; it fires at dial
  /// time, not at the moment the callee actually answers.
  bool get isOffHook => state == 'offhook';

  /// The line has returned to idle — the call has ended.
  bool get isEnded => state == 'idle';

  @override
  String toString() => 'CallEvent($direction/$state)';
}

/// Thin wrapper over the platform channel backed by MainActivity.kt. Calls are
/// placed through the phone's own dialer over the mobile SIM.
class TelephonyService {
  static const _methods = MethodChannel('caller_bot/telephony');
  static const _events = EventChannel('caller_bot/call_events');

  static final Stream<CallEvent> callEvents = _events
      .receiveBroadcastStream()
      .map((raw) {
        final map = Map<String, dynamic>.from(raw as Map);
        return CallEvent(map['state'] as String, map['direction'] as String);
      })
      .asBroadcastStream();

  static Future<void> placeCall(String number) =>
      _methods.invokeMethod('placeCall', {'number': number});

  /// Best-effort programmatic hangup. Returns true only if the platform was
  /// actually able to end the call (requires ANSWER_PHONE_CALLS); otherwise the
  /// call must be ended by hand.
  static Future<bool> endCall() async =>
      await _methods.invokeMethod<bool>('endCall') ?? false;

  static Future<void> setSpeaker(bool on) =>
      _methods.invokeMethod('setSpeaker', {'on': on});

  static Future<void> maxMediaVolume() => _methods.invokeMethod('maxMediaVolume');

  /// Runs [script] as root (single `su` session) and returns its exit code and
  /// combined stdout/stderr. Used for audio-HAL/mixer control on rooted devices.
  static Future<RootResult> runRoot(String script) async {
    final raw = await _methods.invokeMethod('runRoot', {'script': script});
    final map = Map<String, dynamic>.from(raw as Map);
    return RootResult(
      map['exitCode'] as int? ?? -1,
      (map['output'] as String?) ?? '',
    );
  }
}

/// Result of a root shell invocation.
class RootResult {
  final int exitCode;
  final String output;

  const RootResult(this.exitCode, this.output);

  bool get ok => exitCode == 0;

  @override
  String toString() => 'RootResult(exit=$exitCode)\n$output';
}
