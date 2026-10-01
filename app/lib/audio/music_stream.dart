// The desktop app's music: the jukebox's tunes and the DJ on the roof, rendered ahead in chunks by
// music_render.dart in a background isolate and streamed into SoLoud, lined up with the shared clock
// the way the web's players are, so everyone on the floor hears the same bar.
//
// A stream starts a little ahead of now (its first sample is a known moment of the tune), is fed a
// couple of seconds ahead, and is kept in step by nudging its speed a fraction of a percent (or, if
// it's out by more than a moment, by starting again from now). It's heard through a panner (and, for
// the jukebox, a lowpass that muffles it across the room), at your music volume, like the web's.

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:http/http.dart' as http;
import 'package:office_shared/jukebox.dart' show jukeboxStream;
import 'package:office_shared/layout.dart' show DjBooth;

import 'audio_engine.dart';
import 'music_render.dart';
import 'score.dart';
import 'sound_model.dart';
import 'synth.dart' show nativeSampleRate, rmsOf;

/// Where the DJ's speakers are, and how they carry (sound_web.dart's _djIn).
const Pos djSpeakers = Pos(DjBooth.x, 2.2, DjBooth.z);

/// How far ahead of now a stream starts, at first (s): time to render the first chunk.
const double _lead = 0.5;

/// How much is kept rendered ahead of what's playing (s), and how much is asked for at a time.
const double _ahead = 2.0;
const double _chunk = 1.0;

/// Levels are kept every this many samples, for musicLevel().
const int _levelBlock = 1024;

class _Session {
  _Session(this.id, this.tune, this.clock, this.startAt);

  final int id;

  /// The jukebox's track, or null for the DJ.
  final String? tune;

  /// How far into the tune (or the set) it is now, in seconds.
  final double Function() clock;

  /// Where in the tune its first sample is.
  final double startAt;
  int stream = -1;
  int voice = -1;
  double fed = 0;
  bool pending = false;
  bool playing = false;
  bool stopped = false;
  Timer? starting;
  double speed = 1;
  final List<double> levels = [];
  double vol = -1, left = -1, right = -1;

  bool get isDj => tune == null;
}

class MusicStreams {
  MusicStreams(this._engine, this._now);

  final AudioEngine? _engine;
  final double Function() _now;
  static const int _sr = nativeSampleRate;

  /// Whether the engine's running.
  bool ready = false;
  SoundListener listener = const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1);

  JukeboxPlay? _jukebox;
  Score? _score;
  double Function()? _djClock;
  double _volume = 0.5;
  bool _muted = false;
  double _gain = 0;
  double _cutoff = 16000;
  bool _disposed = false;

  _Session? _tune;
  _Session? _dj;
  int _ids = 0;
  double _leadNow = _lead;

  // The render isolate.
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Future<void>? _spawning;
  int _horn = -1;

  bool get isStream => _jukebox?.track == jukeboxStream;

  /// A stream that won't play.
  void Function(String text)? onError;

  // Internet radio (or an audio file): fetched and decoded as it plays.
  int _radio = -1;
  int _radioVoice = -1;
  http.Client? _radioClient;
  int _radioTries = 0;

  /// The tune's stream, for checks.
  bool get tunePlaying => _tune?.playing ?? false;
  bool get djPlaying => _dj?.playing ?? false;

  // ---- What's on ---------------------------------------------------------------------------------

  /// Puts on [play] (null for nothing); returns what to tell you if it can't play here.
  String? setJukebox(JukeboxPlay? play) {
    final was = _jukebox;
    _jukebox = play;
    // The same play sent again (a reconnect, or timed better): the stream keeps itself in step.
    if (was != null && play != null && was.samePlayAs(play)) return null;
    _score = play == null || play.track == jukeboxStream ? null : Score(play.track);
    _stop(_tune, 0.4);
    _tune = null;
    _stopRadio();
    _radioTries = 0;
    _applyJukebox();
    return null;
  }

  void setVolume(double volume, bool muted) {
    _volume = volume.clamp(0, 1).toDouble();
    _muted = muted;
  }

  double get _targetGain => _muted ? 0 : _volume * _volume;

  double _musicAt() {
    final j = _jukebox;
    return j == null ? 0 : math.max(0, (_now() - j.since) / 1000);
  }

  /// 1 on each beat of the tune, falling to 0 before the next.
  double beat() {
    final s = _score;
    return s == null || !ready ? 0 : s.beat(_musicAt());
  }

  /// The DJ's set (see djTime), or null to stop it; returns whether a set started.
  bool setDj(double Function()? clock) {
    final was = _djClock != null;
    _djClock = clock;
    if (was == (clock != null)) return false;
    if (clock == null) {
      _stop(_dj, 0.5);
      _dj = null;
      return false;
    }
    return _applyDj();
  }

  /// The air horn, while the DJ plays.
  bool horn() {
    final e = _engine;
    if (e == null || _dj == null || _horn < 0) return false;
    final h = hearStereoAt(listener, djSpeakers, 7, 0.8);
    e.play(_horn, volume: _gain * h.gain, left: h.left, right: h.right);
    return true;
  }

  /// Starts what's on, now the engine's running.
  void apply() {
    _applyJukebox();
    _applyDj();
  }

  void _applyJukebox() {
    final j = _jukebox;
    if (!ready || _engine == null || j == null) return;
    if (j.track == jukeboxStream) {
      if (_radio < 0) _startRadio(j);
      return;
    }
    _tune ??= _start(j.track, _musicAt);
  }

  // ---- Radio -------------------------------------------------------------------------------------

  void _startRadio(JukeboxPlay j) {
    final e = _engine!;
    final url = j.url;
    final uri = url == null ? null : Uri.tryParse(url);
    if (uri == null || !(uri.isScheme('http') || uri.isScheme('https'))) return;
    final int stream;
    try {
      stream = _radio = e.openCompressedStream();
    } catch (err) {
      debugPrint('radio: $err');
      return;
    }
    final client = _radioClient = http.Client();
    var started = false;
    void fail(Object err) {
      debugPrint('radio: $err');
      if (!identical(_radioClient, client)) return;
      _stopRadio();
      onError?.call("📻 The jukebox can't play that stream in the desktop app");
    }

    unawaited(() async {
      try {
        final res = await client.send(http.Request('GET', uri));
        if (res.statusCode >= 400) return fail('HTTP ${res.statusCode}');
        await for (final bytes in res.stream) {
          if (!identical(_radioClient, client)) return;
          e.feedBytes(stream, Uint8List.fromList(bytes));
          if (!started) {
            started = true;
            _radioVoice = e.play(stream, volume: _radioVolume());
          }
        }
        if (identical(_radioClient, client)) e.endStream(stream);
      } catch (err) {
        fail(err);
      }
    }());
  }

  void _stopRadio() {
    _radioClient?.close();
    _radioClient = null;
    final e = _engine;
    if (e != null && _radio >= 0) {
      final stream = _radio, voice = _radioVoice;
      if (voice >= 0) e.fadeOut(voice, 0.3);
      Timer(const Duration(seconds: 1), () => e.free(stream));
    }
    _radio = _radioVoice = -1;
  }

  /// A stream isn't panned, only turned down with distance (as on the web, where it's an <audio>).
  double _radioVolume() => streamVolume(_targetGain, jukeboxDistance(listener));

  /// An audio file that's played to its end starts again (the web's loops).
  void _keepRadio() {
    final e = _engine;
    final j = _jukebox;
    if (e == null || _radioVoice < 0 || j == null) return;
    if (e.alive(_radioVoice)) {
      e.setVolume(_radioVoice, _radioVolume());
    } else if (_radioTries++ < 20) {
      _stopRadio();
      _startRadio(j);
    }
  }

  bool _applyDj() {
    final clock = _djClock;
    if (!ready || _engine == null || clock == null || _dj != null) return false;
    _dj = _start(null, clock);
    return true;
  }

  // ---- Streams -----------------------------------------------------------------------------------

  _Session _start(String? tune, double Function() clock) {
    final s = _Session(++_ids, tune, clock, clock() + _leadNow);
    s.stream = _engine!.openStream(_sr, 2, lowpass: tune != null);
    unawaited(() async {
      await _spawn();
      if (s.stopped) return;
      _toWorker?.send(tune == null ? ['dj', s.id, s.startAt, _sr] : ['tune', s.id, s.startAt, _sr, tune]);
      _request(s);
    }());
    return s;
  }

  void _request(_Session s) {
    if (s.pending || s.stopped || _toWorker == null) return;
    s.pending = true;
    _toWorker!.send(['more', s.id, (_chunk * _sr).round()]);
  }

  void _stop(_Session? s, double fade) {
    if (s == null || s.stopped) return;
    s.stopped = true;
    s.starting?.cancel();
    _toWorker?.send(['stop', s.id]);
    final e = _engine;
    if (e == null) return;
    if (s.voice >= 0) e.fadeOut(s.voice, fade);
    Timer(Duration(milliseconds: (fade * 1000).round() + 500), () => e.free(s.stream));
  }

  /// Starts again from now, further ahead if it was late.
  void _restart(_Session s, {bool late = false}) {
    if (late) _leadNow = math.min(3, _leadNow * 1.5);
    _stop(s, 0.15);
    if (identical(s, _tune)) {
      _tune = null;
      _applyJukebox();
    } else if (identical(s, _dj)) {
      _dj = null;
      _applyDj();
    }
  }

  void _onChunk(List<Object?> m) {
    if (_disposed) return;
    final id = m[0] as int;
    final e = _engine!;
    if (id < 0) {
      // The air horn, rendered once.
      unawaited(e.load([m[1] as Float32List, m[2] as Float32List], _sr, 'horn').then((h) => _horn = h));
      return;
    }
    final s = [_tune, _dj].firstWhere((s) => s?.id == id, orElse: () => null);
    if (s == null || s.stopped) return;
    final left = m[1] as Float32List, right = m[2] as Float32List;
    try {
      e.feed(s.stream, [left, right]);
    } catch (err) {
      debugPrint('music: $err');
      return;
    }
    for (var i = 0; i + _levelBlock <= left.length; i += _levelBlock) {
      final l = rmsOf(left, i, i + _levelBlock), r = rmsOf(right, i, i + _levelBlock);
      s.levels.add(math.sqrt((l * l + r * r) / 2));
    }
    s.fed += left.length / _sr;
    s.pending = false;
    if (!s.playing && s.starting == null) {
      final wait = s.startAt - s.clock();
      if (wait < 0.02) return _restart(s, late: true);
      s.starting = Timer(Duration(microseconds: (wait * 1e6).round()), () {
        if (s.stopped) return;
        final (vol, l, r) = _levels(s);
        s.voice = e.play(s.stream, volume: vol, left: l, right: r);
        s.vol = vol;
        s.left = l;
        s.right = r;
        s.playing = true;
        if (!s.isDj) e.setLowpass(s.stream, s.voice, _cutoff);
      });
    }
    _keepUp(s);
  }

  (double, double, double) _levels(_Session s) {
    final h = s.isDj
        ? hearStereoAt(listener, djSpeakers, 7, 0.8)
        : hearStereoAt(listener, jukeboxAt, musicRef, musicRolloff);
    return (_gain * h.gain, h.left, h.right);
  }

  /// Keeps a stream fed, and in step with the clock.
  void _keepUp(_Session s) {
    final e = _engine;
    if (e == null || s.stopped) return;
    final played = s.playing ? e.played(s.stream) : 0.0;
    if (s.fed - played < _ahead) _request(s);
    if (!s.playing) return;
    // Behind (positive) or ahead (negative) of everyone else, in seconds.
    final err = s.clock() - (s.startAt + played);
    if (err.abs() > 0.3) return _restart(s, late: err > 0);
    final speed = 1 + (err * 0.05).clamp(-0.004, 0.004);
    if ((speed - s.speed).abs() > 0.0003) {
      s.speed = speed;
      e.setSpeed(s.voice, speed);
    }
  }

  // ---- Every frame -------------------------------------------------------------------------------

  void update() {
    for (final s in [_tune, _dj]) {
      if (s != null) _keepUp(s);
    }
    _keepRadio();
  }

  /// Eases the volume and the jukebox's muffling, and moves the music with you.
  void tick(double dt) {
    final e = _engine;
    if (e == null || !ready) return;
    _gain = _targetGain + (_gain - _targetGain) * math.exp(-dt / 0.04);
    final cutoff = musicCutoffAt(jukeboxDistance(listener));
    _cutoff = cutoff + (_cutoff - cutoff) * math.exp(-dt / 0.1);
    for (final s in [_tune, _dj]) {
      if (s == null || !s.playing || s.stopped) continue;
      final (vol, l, r) = _levels(s);
      if ((vol - s.vol).abs() > 1e-4 + s.vol * 0.01) {
        s.vol = vol;
        e.setVolume(s.voice, vol);
      }
      if ((l - s.left).abs() > 0.005 || (r - s.right).abs() > 0.005) {
        s.left = l;
        s.right = r;
        e.setPan(s.voice, l, r);
      }
      if (!s.isDj) e.setLowpass(s.stream, s.voice, _cutoff);
    }
  }

  /// The music's level (RMS) where you stand, after your music volume.
  double level() {
    final e = _engine;
    var sum = 0.0;
    for (final s in [_tune, _dj]) {
      if (e == null || s == null || !s.playing || s.stopped) continue;
      final i = (e.played(s.stream) * _sr / _levelBlock).floor();
      if (i < 0 || i >= s.levels.length) continue;
      final v = s.levels[i] * s.vol;
      sum += v * v;
    }
    return math.sqrt(sum);
  }

  void dispose() {
    _disposed = true;
    _stopRadio();
    _stop(_tune, 0.2);
    _stop(_dj, 0.2);
    _tune = _dj = null;
    _toWorker?.send(['exit']);
    _fromWorker?.close();
  }

  // ---- The render isolate ------------------------------------------------------------------------

  Future<void> _spawn() => _spawning ??= () async {
    final inbox = ReceivePort();
    _fromWorker = inbox;
    final ready = Completer<SendPort>();
    inbox.listen((m) {
      if (m is SendPort) {
        ready.complete(m);
      } else if (m is List<Object?>) {
        _onChunk(m);
      }
    });
    await Isolate.spawn(_musicWorker, inbox.sendPort, debugName: 'music');
    _toWorker = await ready.future;
    _toWorker!.send(['horn', _sr]);
  }();
}

/// The render isolate: a TuneRender or DjRender per stream, a chunk at a time.
void _musicWorker(SendPort out) {
  final inbox = ReceivePort();
  out.send(inbox.sendPort);
  final renders = <int, Object>{};
  inbox.listen((msg) {
    final m = msg as List<Object?>;
    switch (m[0]) {
      case 'tune':
        renders[m[1] as int] = TuneRender(m[3] as int, m[4] as String, m[2] as double);
      case 'dj':
        renders[m[1] as int] = DjRender(m[3] as int, m[2] as double);
      case 'more':
        final r = renders[m[1] as int];
        final n = m[2] as int;
        final c = r is TuneRender ? r.render(n) : (r is DjRender ? r.render(n) : null);
        if (c != null) out.send([m[1], c.left, c.right]);
      case 'horn':
        final h = renderHorn(m[1] as int);
        out.send([-1, h[0], h[1]]);
      case 'stop':
        renders.remove(m[1] as int);
      case 'exit':
        inbox.close();
    }
  });
}
