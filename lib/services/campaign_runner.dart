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
  });

  /// Where the voice message audio lives. Either an asset path or a device
  /// file path picked by the user.
  final Source audioSource;
  final int maxAttempts;
  final Duration ringTimeout;
  final Duration pauseBetweenCalls;

  final List<CallTarget> targets = [];
  final _player = AudioPlayer();

  StreamSubscription<CallEvent>? _callSub;
  StreamSubscription<void>? _playerCompleteSub;

  bool _running = false;
  bool _cancelRequested = false;
  int _currentIndex = -1;
  String? _statusMessage;

  bool get isRunning => _running;
  int get currentIndex => _currentIndex;
  String? get statusMessage => _statusMessage;

  // Per-attempt coordination handles. Completed by the call-state listener.
  Completer<void>? _answered; // completes when call goes active
  Completer<void>? _ended; // completes when call disconnects

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

      final answered = await _placeAndWaitForAnswer(target.number);

      if (_cancelRequested) {
        await _safeHangup();
        return;
      }

      if (answered) {
        target.status = TargetStatus.playingMessage;
        _setStatus('Answered — playing message to ${target.number}');
        notifyListeners();
        await _playMessageThenHangup();
        target.status = TargetStatus.delivered;
        return;
      }

      // No answer this attempt: make sure the dialer is torn down before retry.
      await _safeHangup();
      _setStatus('No answer from ${target.number} (attempt $attempt)');
      notifyListeners();
      if (attempt < maxAttempts) await _sleep(pauseBetweenCalls);
    }
    target.status = TargetStatus.noAnswer;
  }

  /// Places the call and resolves true if it becomes active before the ring
  /// timeout, false otherwise. Always leaves no call ringing on a false result
  /// via the caller's hangup.
  Future<bool> _placeAndWaitForAnswer(String number) async {
    _answered = Completer<void>();
    _ended = Completer<void>();

    try {
      await TelephonyService.placeCall(number);
    } catch (e) {
      _setStatus('Could not place call to $number: $e');
      return false;
    }

    final answeredFuture = _answered!.future.then((_) => true);
    final endedFuture = _ended!.future.then((_) => false);
    final timeoutFuture =
        Future.delayed(ringTimeout).then((_) => false);

    // First of: answered / remote-hangup / our ring timeout.
    return await Future.any([answeredFuture, endedFuture, timeoutFuture]);
  }

  Future<void> _playMessageThenHangup() async {
    final done = Completer<void>();
    _playerCompleteSub?.cancel();
    _playerCompleteSub = _player.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });

    try {
      await TelephonyService.setSpeaker(true);
      await TelephonyService.maxMediaVolume();
      await _player.stop();
      await _player.play(audioSource);

      // Guard against a stuck player: fall back to hanging up after a
      // generous ceiling even if onPlayerComplete never fires.
      await Future.any([done.future, Future.delayed(const Duration(minutes: 3))]);
    } catch (e) {
      _setStatus('Playback error: $e');
    } finally {
      await _playerCompleteSub?.cancel();
      _playerCompleteSub = null;
      await _player.stop();
      await _safeHangup();
      // Give telecom a beat to actually drop the call.
      await _waitForEndOrTimeout(const Duration(seconds: 5));
    }
  }

  void _listenToCalls() {
    _callSub?.cancel();
    _callSub = TelephonyService.callEvents.listen((event) {
      // We only care about the call we initiated (outgoing).
      if (event.isIncoming) return;
      switch (event.state) {
        case 'active':
          if (_answered != null && !_answered!.isCompleted) {
            _answered!.complete();
          }
          break;
        case 'disconnected':
          if (_ended != null && !_ended!.isCompleted) {
            _ended!.complete();
          }
          break;
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
    _playerCompleteSub?.cancel();
    _player.dispose();
    super.dispose();
  }
}
