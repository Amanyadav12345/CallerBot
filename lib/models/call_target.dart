enum TargetStatus {
  pending,
  calling,
  playingMessage,
  delivered, // answered and full message played
  noAnswer, // exhausted all attempts without an answer
  failed, // call could not be placed / other error
}

class CallTarget {
  final String number;
  int attemptsMade = 0;
  TargetStatus status = TargetStatus.pending;
  String? note;

  CallTarget(this.number);

  String get statusLabel => switch (status) {
        TargetStatus.pending => 'Pending',
        TargetStatus.calling => 'Calling…',
        TargetStatus.playingMessage => 'Playing message…',
        TargetStatus.delivered => 'Delivered',
        TargetStatus.noAnswer => 'No answer',
        TargetStatus.failed => 'Failed',
      };
}
