import 'dart:async';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

import '../models/call_target.dart';
import 'telephony_service.dart';

/// Drives the whole campaign: for each number, ring up to [maxAttempts] times,
/// and the moment a call is answered, play the voice message to the end, then
/// hang up and move on to the next person.
class CampaignRunner extends ChangeNotifier {
  CampaignRunner({
    required this.audioSource,
    this.maxAttempts = 3,
    this.ringTimeout = const Duration(seconds: 30),
    this.pauseBetweenCalls = const Duration(seconds: 3),
    this.maxTalkTime = const Duration(seconds: 45),
  });

  /// Where the voice message audio lives. Either an asset path or a device
  /// file path picked by the user.
  final Source audioSource;
  final int maxAttempts;
  final Duration ringTimeout;
  final Duration pauseBetweenCalls;

  /// How long to keep the (looping) message playing on the call before we hang
  /// up, if the other party doesn't hang up first. Because the native dialer
  /// gives us no "answered" signal, we loop the message for this whole window
  /// so the person hears it whenever they pick up.
  final Duration maxTalkTime;

  /// How long to wait for the off-hook signal after dialling before starting
  /// the message anyway (so playback doesn't depend on phone-state events).
  static const Duration _connectGrace = Duration(seconds: 5);

  /// Routes the message out of the loudspeaker so its sound couples into the
  /// call's microphone and the far end can hear it. Injecting audio straight
  /// into a cellular call's uplink isn't possible on Android, so this acoustic
  /// path via the speaker is the only option.
  static final AudioContext _callAudioContext = AudioContext(
    android: AudioContextAndroid(
      isSpeakerphoneOn: true,
      stayAwake: true,
      contentType: AndroidContentType.music,
      usageType: AndroidUsageType.media,
      audioFocus: AndroidAudioFocus.gainTransientMayDuck,
    ),
  );

  final List<CallTarget> targets = [];
  final _player = AudioPlayer();

  StreamSubscription<CallEvent>? _callSub;

  bool _running = false;
  bool _cancelRequested = false;
  int _currentIndex = -1;
  String? _statusMessage;

  bool get isRunning => _running;
  int get currentIndex => _currentIndex;
  String? get statusMessage => _statusMessage;

  // Per-attempt coordination handles. Completed by the call-state listener.
  Completer<void>? _connected; // completes when the line goes off-hook
  Completer<void>? _ended; // completes when the line returns to idle

  void loadNumbers(Iterable<String> numbers) {
    if (_running) return;
    targets
      ..clear()
      ..addAll(_dedupeAndClean(numbers).map(CallTarget.new));
    _currentIndex = -1;
    _statusMessage = null;
    notifyListeners();
  }

  Iterable<String> _dedupeAndClean(Iterable<String> numbers) {
    final seen = <String>{};
    return numbers
        .map((n) => n.replaceAll(RegExp(r'[\s\-()]'), '').trim())
        .where((n) => n.isNotEmpty && seen.add(n));
  }

  Future<void> start() async {
    if (_running || targets.isEmpty) return;
    _running = true;
    _cancelRequested = false;
    _listenToCalls();
    notifyListeners();

    try {
      for (var i = 0; i < targets.length; i++) {
        if (_cancelRequested) break;
        _currentIndex = i;
        await _runTarget(targets[i]);
        notifyListeners();
        if (_cancelRequested) break;
        if (i < targets.length - 1) {
          await _sleep(pauseBetweenCalls);
        }
      }
    } finally {
      await _finish();
    }
  }

  Future<void> _runTarget(CallTarget target) async {
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_cancelRequested) return;
      target.attemptsMade = attempt;
      target.status = TargetStatus.calling;
      _setStatus('Calling ${target.number} (attempt $attempt/$maxAttempts)');
      notifyListeners();

      final connected = await _placeAndWaitForConnect(target.number);

      if (_cancelRequested) {
        await _safeHangup();
        return;
      }

      if (connected) {
        // The native dialer gives us no "answered" signal, so we loop the
        // message on the loudspeaker for the whole call so the person hears it
        // whenever they pick up, then hang up.
        target.status = TargetStatus.playingMessage;
        _setStatus('On call — playing message to ${target.number}');
        notifyListeners();
        await _playMessageDuringCall();
        target.status = TargetStatus.delivered;
        return;
      }

      // Call never reached the line (dial blocked/failed): retry.
      await _safeHangup();
      _setStatus('Could not connect to ${target.number} (attempt $attempt)');
      notifyListeners();
      if (attempt < maxAttempts) await _sleep(pauseBetweenCalls);
    }
    target.status = TargetStatus.noAnswer;
  }

  /// Places the call through the native dialer and resolves true once the call
  /// is on the line. Prefers the real off-hook signal, but doesn't depend on
  /// it: if phone-state events aren't delivered we assume the call is up after
  /// a short grace period so the message still plays. Returns false only if the
  /// call couldn't be placed or the line dropped straight back to idle.
  Future<bool> _placeAndWaitForConnect(String number) async {
    _connected = Completer<void>();
    _ended = Completer<void>();

    try {
      await TelephonyService.placeCall(number);
    } catch (e) {
      _setStatus('Could not place call to $number: $e');
      return false;
    }

    await Future.any([
      _connected!.future,
      _ended!.future,
      Future.delayed(_connectGrace),
    ]);

    // Line already went back to idle => the call failed / was declined instantly.
    return !_ended!.isCompleted;
  }

  Future<void> _playMessageDuringCall() async {
    final ended = _ended;

    // Route to speaker + max the media volume before playing (best-effort).
    await _tryStep(() => TelephonyService.setSpeaker(true));
    await _tryStep(() => TelephonyService.maxMediaVolume());

    try {
      // Start from a clean player state, then prepare the source BEFORE setting
      // loop mode. Calling setReleaseMode (setLooping) on a player with no
      // prepared source throws MediaPlayer error -38 (INVALID_OPERATION) and
      // wedges the player, which then makes the actual playback fail too.
      await _tryStep(() => _player.release());
      await _tryStep(() => _player.setAudioContext(_callAudioContext));
      await _player.setSource(audioSource);
      await _player.setReleaseMode(ReleaseMode.loop);
      await _player.setVolume(1);
      await _player.resume();
      _setStatus('Playing your message on the call…');
      notifyListeners();

      // Keep playing until the call ends (either party hangs up) or the talk
      // window elapses — whichever comes first.
      await Future.any([
        if (ended != null) ended.future,
        Future.delayed(maxTalkTime),
      ]);
    } catch (e) {
      _setStatus('Could not play the message: $e');
    } finally {
      // Stop the audio the instant the call is over so nothing leaks out after
      // the call is cut, then make sure the call is torn down.
      await _tryStep(() => _player.stop());
      await _safeHangup();
      // Wait for the line to actually return to idle before we move on, so we
      // never place the next call on top of one that's still connected. If the
      // programmatic hangup wasn't permitted, this waits for a manual hangup.
      await _waitForEndOrTimeout(const Duration(seconds: 30));
    }
  }

  /// Runs a best-effort setup/teardown step, logging but never rethrowing so a
  /// single failing call can't stop the message from playing.
  Future<void> _tryStep(Future<void> Function() step) async {
    try {
      await step();
    } catch (e) {
      if (kDebugMode) debugPrint('[CampaignRunner] step failed: $e');
    }
  }

  void _listenToCalls() {
    _callSub?.cancel();
    _callSub = TelephonyService.callEvents.listen((event) {
      // We only care about the call we initiated (outgoing).
      if (event.isIncoming) return;
      if (event.isOffHook) {
        if (_connected != null && !_connected!.isCompleted) {
          _connected!.complete();
        }
      } else if (event.isEnded) {
        if (_ended != null && !_ended!.isCompleted) {
          _ended!.complete();
        }
      }
    });
  }

  Future<void> _waitForEndOrTimeout(Duration limit) async {
    final ended = _ended;
    if (ended == null || ended.isCompleted) return;
    await Future.any([ended.future, Future.delayed(limit)]);
  }

  Future<void> _safeHangup() async {
    try {
      await TelephonyService.endCall();
    } catch (_) {
      // Call may already be gone; ignore.
    }
  }

  Future<void> _sleep(Duration d) async {
    if (_cancelRequested) return;
    await Future.delayed(d);
  }

  void cancel() {
    if (!_running) return;
    _cancelRequested = true;
    _setStatus('Stopping…');
    _safeHangup();
    notifyListeners();
  }

  Future<void> _finish() async {
    _running = false;
    _cancelRequested = false;
    await _callSub?.cancel();
    _callSub = null;
    await _player.stop();
    _setStatus(_summary());
    notifyListeners();
  }

  String _summary() {
    final delivered =
        targets.where((t) => t.status == TargetStatus.delivered).length;
    return 'Done — $delivered/${targets.length} delivered';
  }

  void _setStatus(String msg) {
    _statusMessage = msg;
    if (kDebugMode) debugPrint('[CampaignRunner] $msg');
  }

  @override
  void dispose() {
    _callSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
