// Emotes: a quick reaction (a wave, a thumbs up…) your character does for everyone on your floor.
// Server and client share the list, so an emote is just its id on the wire. Port of src/shared/emotes.ts.

import 'dart:math' as math;

import 'json_util.dart';

/// An emote, by its id on the wire (`EmoteId` in the TS), with what the wheel shows for it.
enum Emote implements WireEnum {
  wave('wave', '👋', 'Wave', 2.2),
  thumbs('thumbs', '👍', 'Thumbs up', 1.8),
  clap('clap', '👏', 'Clap', 2.2),
  dance('dance', '🕺', 'Dance', 4),
  point('point', '👉', 'Point', 2),
  facepalm('facepalm', '🤦', 'Facepalm', 2.4);

  const Emote(this.wire, this.emoji, this.label, this.seconds);
  @override
  final String wire;
  final String emoji;
  final String label;

  /// How long your character does it for.
  final double seconds;

  String get id => wire;

  static Emote? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// Every emote, in the wheel's order.
const List<Emote> emotes = Emote.values;

final Map<String, Emote> emoteById = Map.unmodifiable({for (final e in emotes) e.wire: e});

bool isEmote(Object? x) => x is String && emoteById.containsKey(x);

/// A few emotes in a row are fine; after that, one every this many milliseconds.
const int emoteBurst = 3;
const int emoteEvery = 2000;

/// The emote rate limit: a bucket of [emoteBurst], refilled one every `every` ms. The page checks
/// before it plays one, and the server again (a little more leniently, as messages can bunch up
/// on the way) before everyone else sees it.
class EmoteBucket {
  EmoteBucket([this.every = emoteEvery]);

  final num every;
  double _tokens = emoteBurst.toDouble();
  num _at = 0;

  /// Uses one up if there's one left at [now] (ms); false means too soon.
  bool take(num now) {
    _tokens = math.min(emoteBurst.toDouble(), _tokens + (now - _at) / every);
    _at = now;
    if (_tokens < 1) return false;
    _tokens -= 1;
    return true;
  }
}
