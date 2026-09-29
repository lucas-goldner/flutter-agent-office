// Port of tests/emotes.test.ts.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('the wheel has the six emotes from the issue, each with an emoji', () {
    expect([for (final e in emotes) e.id], ['wave', 'thumbs', 'clap', 'dance', 'point', 'facepalm']);
    for (final e in emotes) {
      expect(e.emoji.isNotEmpty && e.label.isNotEmpty && e.seconds > 0, isTrue);
    }
  });

  test('only known emotes get through', () {
    expect(isEmote('wave'), isTrue);
    expect(isEmote('moonwalk'), isFalse);
    expect(isEmote(1), isFalse);
    expect(isEmote(null), isFalse);
  });

  test('a burst of emotes, then one every emoteEvery ms', () {
    final b = EmoteBucket();
    const t0 = 1000000;
    for (var i = 0; i < emoteBurst; i++) {
      expect(b.take(t0), isTrue, reason: 'emote ${i + 1} of the burst');
    }
    expect(b.take(t0), isFalse, reason: 'one too many');
    expect(b.take(t0 + emoteEvery * 0.9), isFalse, reason: 'still too soon');
    expect(b.take(t0 + emoteEvery), isTrue, reason: 'one more after a wait');
    expect(b.take(t0 + emoteEvery + 10), isFalse);
  });

  test('mashing the keys never gets more through than the burst plus the refill', () {
    final b = EmoteBucket();
    var passed = 0;
    // Ten seconds of pressing an emote key every 50 ms.
    for (var t = 0; t <= 10000; t += 50) {
      if (b.take(1000000 + t)) passed++;
    }
    expect(passed, emoteBurst + 10000 ~/ emoteEvery);
  });

  test("the server's more lenient bucket lets through everything the page's does, even bunched up on the way", () {
    final page = EmoteBucket();
    final server = EmoteBucket(emoteEvery * 0.8);
    // Sent as fast as the page allows for ten seconds. The opening burst is held up on the wire and
    // arrives late, all at once; the next one gets there straight away.
    var sent = 0;
    for (var t = 1000000; t <= 1010000; t += 50) {
      if (!page.take(t)) continue;
      final delay = sent++ < emoteBurst ? 300 : 0;
      expect(server.take(t + delay), isTrue, reason: 'emote $sent sent at $t arrives at ${t + delay}');
    }
    expect(sent, greaterThan(emoteBurst + 3));
  });
}
