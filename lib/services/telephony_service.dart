import 'package:flutter/services.dart';

/// A single call-state event coming up from the Android InCallService.
class CallEvent {
  final String state; // connecting, dialing, ringing, active, disconnected, ...
  final String direction; // incoming | outgoing

  const CallEvent(this.state, this.direction);

  bool get isIncoming => direction == 'incoming';

  @override
  String toString() => 'CallEvent($direction/$state)';
}

/// Thin wrapper over the platform channels backed by MainActivity.kt and
/// BotInCallService.kt.
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

  static Future<bool> isDefaultDialer() async =>
      await _methods.invokeMethod<bool>('isDefaultDialer') ?? false;

  static Future<bool> requestDefaultDialer() async =>
      await _methods.invokeMethod<bool>('requestDefaultDialer') ?? false;

  static Future<void> placeCall(String number) =>
      _methods.invokeMethod('placeCall', {'number': number});

  static Future<void> endCall() => _methods.invokeMethod('endCall');

  static Future<void> answerCall() => _methods.invokeMethod('answerCall');

  static Future<void> rejectCall() => _methods.invokeMethod('rejectCall');

  static Future<void> setSpeaker(bool on) =>
      _methods.invokeMethod('setSpeaker', {'on': on});

  static Future<void> maxMediaVolume() => _methods.invokeMethod('maxMediaVolume');
}
