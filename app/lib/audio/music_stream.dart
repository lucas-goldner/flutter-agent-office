// The desktop app's music: the jukebox's tunes and the DJ on the roof, rendered ahead in chunks
// (music_render.dart) and streamed into SoLoud, lined up with the shared clock the way the web's
// players are (everyone on the floor hears the same bar).

import 'dart:math' as math;

import 'package:office_shared/jukebox.dart' show jukeboxStream;

import 'audio_engine.dart';
import 'dnb_score.dart';
import 'score.dart';
import 'sound_model.dart';

class MusicStreams {
  MusicStreams(this._engine, this._now);

  final AudioEngine? _engine;
  final double Function() _now;

  /// Whether the engine's running.
  bool ready = false;
  SoundListener listener = const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1);

  JukeboxPlay? _jukebox;
  Score? _score;
  double Function()? _djClock;
  double _volume = 0.5;
  bool _muted = false;

  bool get isStream => _jukebox?.track == jukeboxStream;

  /// Puts on [play] (null for nothing); returns what to tell you if it can't play here.
  String? setJukebox(JukeboxPlay? play) {
    final was = _jukebox;
    _jukebox = play;
    if (was != null && play != null && was.samePlayAs(play)) return null;
    _score = play == null || play.track == jukeboxStream ? null : Score(play.track);
    final radio = play != null && play.track == jukeboxStream;
    return radio ? "📻 The jukebox's radio doesn't play in the desktop app yet" : null;
  }

  void setVolume(double volume, bool muted) {
    _volume = volume.clamp(0, 1).toDouble();
    _muted = muted;
  }

  double get gain => _muted ? 0 : _volume * _volume;

  double _musicAt() {
    final j = _jukebox;
    return j == null ? 0 : math.max(0, (_now() - j.since) / 1000);
  }

  /// 1 on each beat of the tune, falling to 0 before the next.
  double beat() {
    final s = _score;
    return s == null ? 0 : s.beat(_musicAt());
  }

  /// Returns whether a set started.
  bool setDj(double Function()? clock) {
    final was = _djClock != null;
    _djClock = clock;
    return !was && clock != null && ready && _engine != null;
  }

  bool horn() => false;

  void apply() {}
  void update() {}
  void tick(double dt) {}
  double level() => 0;
  void dispose() {}

  /// For checks: the DJ's bar now.
  int djBarNow() => ((_djClock?.call() ?? 0) / djBar).floor();
}
