// The jukebox's tunes (music.dart's TunePlayer) and the DJ's set (dnb.dart's DjPlayer), rendered a
// chunk at a time by the offline synth (synth.dart) for the desktop app to stream (music_stream.dart).
//
// A renderer starts at a moment in the tune (or the set): its first sample is that moment, and every
// note lands where score.dart (dnb_score.dart) says, so it plays the same bar everyone else hears.
// Each note is rendered whole when it starts, into the bus it plays through, and the buses' filters,
// the room's reverb and the compressors run on, chunk after chunk, with their state carried over.
//
// Pure Dart: tested on the VM, and run in a background isolate in the app.

import 'dart:math' as math;
import 'dart:typed_data';

import 'dnb_score.dart';
import 'samples.dart';
import 'score.dart';
import 'synth.dart';

/// A stereo chunk of music, and its level every 1024 samples (for the lights and checks).
class MusicChunk {
  MusicChunk(this.left, this.right);

  final Float32List left;
  final Float32List right;
}

/// Sound still to come on one bus: notes are added whole when they start, and taken off the front a
/// chunk at a time.
class _Acc {
  Float32List _d = Float32List(1 << 16);

  /// The absolute sample index of `_d[0]`.
  int _base = 0;

  /// Adds [src] from absolute sample [at] on.
  void add(int at, Float32List src, [double k = 1]) {
    var from = 0;
    if (at < _base) {
      from = _base - at;
      at = _base;
    }
    final need = at - _base + src.length - from;
    if (need > _d.length) {
      var n = _d.length;
      while (n < need) {
        n *= 2;
      }
      _d = Float32List(n)..setRange(0, _d.length, _d);
    }
    final o = at - _base - from;
    for (var i = from; i < src.length; i++) {
      _d[o + i] += src[i] * k;
    }
  }

  /// The next [n] samples, which it then forgets.
  Float32List take(int n) {
    final out = Float32List(n);
    final m = math.min(n, _d.length);
    out.setRange(0, m, _d);
    if (n >= _d.length) {
      _d.fillRange(0, _d.length, 0);
    } else {
      _d.setRange(0, _d.length - n, _d, n);
      _d.fillRange(_d.length - n, _d.length, 0);
    }
    _base += n;
    return out;
  }
}

/// A streaming AudioParam with setValueAtTime and setTargetAtTime (what a bus's automation needs),
/// stepped a sample at a time.
class _Auto {
  _Auto(this.value);

  double value;
  double _target = 0;
  double _k = 0; // per-sample easing; 0 for none
  final List<(int, bool, double, double)> _events = []; // (sample, isTarget, value, timeConstant)

  void set(int at, double v) => _insert((at, false, v, 0));
  void target(int at, double v, double tc) => _insert((at, true, v, tc));

  void _insert((int, bool, double, double) e) {
    var i = _events.length;
    while (i > 0 && _events[i - 1].$1 > e.$1) {
      i--;
    }
    _events.insert(i, e);
  }

  /// The value at absolute sample [i] (called with i increasing by one).
  double step(int i, int sr) {
    while (_events.isNotEmpty && _events.first.$1 <= i) {
      final (_, isTarget, v, tc) = _events.removeAt(0);
      if (isTarget) {
        _target = v;
        _k = 1 - math.exp(-1 / (tc * sr));
      } else {
        value = v;
        _k = 0;
      }
    }
    if (_k > 0) value += (_target - value) * _k;
    return value;
  }
}

/// A gain envelope: 0.0001 → [peak] exponentially over [attack], then down again over [decay].
Param _env(double peak, double attack, double decay) => Param(1)
  ..setValueAtTime(0.0001, 0)
  ..exponentialRampToValueAtTime(peak, attack)
  ..exponentialRampToValueAtTime(0.0001, attack + decay);

// ---- The jukebox --------------------------------------------------------------------------------------

/// The tune's level after its compressor (music.dart).
const double _tuneLevel = 0.75;

/// Renders [track] from [startAt] seconds into it, a chunk at a time.
class TuneRender {
  TuneRender(this.sr, String track, this.startAt, {int seed = 1, this.lastStep})
    : score = Score(track),
      _rng = math.Random(seed),
      _samples = TuneSamples(sr, math.Random(seed)) {
    _conv = Convolver(_samples.room, sr, block: 2048);
    _comp = Compressor(threshold: -20, ratio: 3, attack: 0.01, release: 0.2, sr: sr);
    _next = math.max(0, (startAt / score.step).ceil());
    while (score.stepTime(_next) < startAt - 1e-9) {
      _next++;
    }
  }

  final int sr;
  final Score score;
  final double startAt;

  /// No notes after this 16th (for checks: a bar on its own).
  final int? lastStep;
  final math.Random _rng;
  final TuneSamples _samples;

  /// Absolute samples rendered so far.
  int _done = 0;
  late int _next;

  final _keys = _Acc(), _melody = _Acc(), _bass = _Acc(), _hat = _Acc(), _dry = _Acc(), _reverbIn = _Acc();
  final _keysTone = Biquad.fixed(BiquadType.lowpass, 2400, 0.6);
  final _melodyTone = Biquad.fixed(BiquadType.lowpass, 3000, 0.7);
  final _bassTone = Biquad.fixed(BiquadType.lowpass, 420, 0.8);
  final _hatTone = Biquad.fixed(BiquadType.highpass, 6500, 0.7);
  final _dullL = Biquad.fixed(BiquadType.lowpass, 5200, 0.5);
  final _dullR = Biquad.fixed(BiquadType.lowpass, 5200, 0.5);
  final _crackleTone = Biquad.fixed(BiquadType.highpass, 900, 0.7);
  late final Convolver _conv;
  late final Compressor _comp;
  int _crackleAt = 0;

  /// Notes started so far.
  int notes = 0;

  /// Seconds since the stream began at absolute sample [i].
  double _t(int i) => i / sr;

  /// The next [n] samples (stereo).
  MusicChunk render(int n) {
    final until = startAt + (_done + n) / sr;
    for (; score.stepTime(_next) < until && _next <= (lastStep ?? _next); _next++) {
      final at = score.stepTime(_next) - startAt;
      for (final e in score.eventsAt(_next)) {
        _note(e, at);
      }
    }
    final keys = _keysTone.process(_keys.take(n), sr);
    final melody = _melodyTone.process(_melody.take(n), sr);
    final bass = _bassTone.process(_bass.take(n), sr);
    final hat = _hatTone.process(_hat.take(n), sr);
    final dry = _dry.take(n);
    final rev = _reverbIn.take(n);
    for (var i = 0; i < n; i++) {
      // The keys wobble in volume a little, like a Rhodes' tremolo.
      final trem = 0.85 + 0.15 * math.sin(2 * math.pi * 3.2 * _t(_done + i));
      final k = keys[i] * trem;
      dry[i] += k + melody[i] + bass[i] + hat[i];
      rev[i] += k + melody[i];
    }
    final wet = _conv.process(rev);
    final left = Float32List(n), right = Float32List(n);
    for (var i = 0; i < n; i++) {
      left[i] = (dry[i] + wet[0][i] * 0.35) * 0.8;
      right[i] = (dry[i] + wet[1][i] * 0.35) * 0.8;
    }
    _dullL.process(left, sr);
    _dullR.process(right, sr);
    _comp.process(left, right);
    // The needle in the groove, under it all.
    final crackle = Float32List(n);
    final c = _samples.crackle;
    for (var i = 0; i < n; i++) {
      crackle[i] = c[_crackleAt];
      _crackleAt = (_crackleAt + 1) % c.length;
    }
    _crackleTone.process(crackle, sr);
    for (var i = 0; i < n; i++) {
      final t = _t(_done + i);
      final fade = t >= 1.5 ? _tuneLevel : _tuneLevel * t / 1.5;
      left[i] = (left[i] + crackle[i] * 0.05) * fade;
      right[i] = (right[i] + crackle[i] * 0.05) * fade;
    }
    _done += n;
    return MusicChunk(left, right);
  }

  void _note(NoteEvent e, double at) {
    notes++;
    final i = (at * sr).round();
    switch (e.voice) {
      case Voice.kick:
        _dry.add(i, _kick(e.vel));
      case Voice.snare:
        final s = _snare(e.vel);
        _dry.add(i, s);
        _reverbIn.add(i, s);
      case Voice.hat:
        _hat.add(i, _hatNote(e.vel));
      case Voice.bass:
        _bass.add(i, _bassNote(e.midi, e.len));
      case Voice.key:
        final j = ((at + e.delay) * sr).round();
        _keys.add(j, _key(e.midi, e.len, e.vel, at + e.delay));
      case Voice.lead:
        _melody.add(i, _lead(e.midi, e.len, at));
    }
  }

  Float32List _kick(double vel) {
    final n = sampleCount(0.45, sr);
    final f = Param(115)
      ..setValueAtTime(115, 0)
      ..exponentialRampToValueAtTime(44, 0.12);
    return gain(osc(n, sr, Wave.sine, f), sr, _env(0.85 * vel, 0.006, 0.42 - 0.006));
  }

  Float32List _snare(double vel) {
    final n = sampleCount(0.25, sr);
    final rattle = biquad(noise(n, sr, _rng), sr, BiquadType.bandpass, 1900, 0.9);
    final f = Param(190)
      ..setValueAtTime(190, 0)
      ..exponentialRampToValueAtTime(140, 0.08);
    final body = gain(osc(n, sr, Wave.triangle, f, stop: 0.12), sr, _env(0.25 * vel, 0.003, 0.097));
    mixInto(rattle, body);
    return gain(rattle, sr, _env(0.32 * vel, 0.004, 0.216));
  }

  Float32List _hatNote(double vel) => gain(noise(sampleCount(0.06, sr), sr, _rng), sr, _env(0.13 * vel, 0.002, 0.043));

  Float32List _bassNote(int midi, double len) {
    final n = sampleCount(len + 0.4, sr);
    final f = mtof(midi);
    final out = osc(n, sr, Wave.sine, Param(f));
    mixInto(out, osc(n, sr, Wave.triangle, Param(f * 2)), k: 0.18);
    final g = Param(0)
      ..setValueAtTime(0, 0)
      ..linearRampToValueAtTime(0.34, 0.012)
      ..setTargetAtTime(0.24, 0.012, 0.3)
      ..setTargetAtTime(0, len, 0.05);
    return gain(out, sr, g);
  }

  /// The tape's slow wobble and the melody's vibrato (cents), at stream time [t].
  double _wobble(double t) => 9 * math.sin(2 * math.pi * 0.37 * t);
  double _vibrato(double t) => 7 * math.sin(2 * math.pi * 5.2 * t);

  /// An electric piano note: a sine, brightened for a moment by another at the same pitch.
  Float32List _key(int midi, double len, double vel, double at) {
    final n = sampleCount(len + 0.8, sr);
    final f = mtof(midi);
    final depth = Param(1)
      ..setValueAtTime(f * 1.4 * vel, 0)
      ..exponentialRampToValueAtTime(f * 0.12, 0.5);
    final mod = gain(osc(n, sr, Wave.sine, Param(f)), sr, depth);
    final wob = Float32List(n);
    for (var i = 0; i < n; i++) {
      wob[i] = _wobble(at + i / sr);
    }
    final car = osc(n, sr, Wave.sine, Param(f), detune: Param((hash(midi, 5) - 0.5) * 8), fm: mod, detuneMod: wob);
    final g = Param(0)
      ..setValueAtTime(0, 0)
      ..linearRampToValueAtTime(0.085 * vel, 0.006)
      ..setTargetAtTime(0.035 * vel, 0.006, 0.5)
      ..setTargetAtTime(0, len, 0.12);
    return gain(car, sr, g);
  }

  Float32List _lead(int midi, double len, double at) {
    final n = sampleCount(len + 0.6, sr);
    final mod = Float32List(n);
    for (var i = 0; i < n; i++) {
      final t = at + i / sr;
      mod[i] = _wobble(t) + _vibrato(t);
    }
    final o = osc(n, sr, Wave.triangle, Param(mtof(midi)), detuneMod: mod);
    final g = Param(0)
      ..setValueAtTime(0, 0)
      ..linearRampToValueAtTime(0.075, 0.03)
      ..setTargetAtTime(0.05, 0.03, 0.4)
      ..setTargetAtTime(0, len, 0.1);
    return gain(o, sr, g);
  }
}

// ---- The DJ ---------------------------------------------------------------------------------------------

/// The set's level after its compressor (dnb.dart).
const double _djLevel = 0.9;

/// Renders the DJ's set from [startAt] seconds into it (see djTime), a chunk at a time.
class DjRender {
  DjRender(this.sr, this.startAt, {int seed = 1, this.lastStep})
    : _rng = math.Random(seed),
      _samples = TuneSamples(sr, math.Random(seed)) {
    _conv = Convolver(_samples.room, sr, block: 2048);
    _comp = Compressor(threshold: -16, knee: 8, ratio: 4, attack: 0.005, release: 0.12, sr: sr);
    _echo = FeedbackEcho(djStep * 3, sr, 0.38, 0.45);
    _next = (startAt / djStep).ceil();
    _curve = driveCurve(2.2);
  }

  final int sr;
  final double startAt;

  /// No notes after this 16th (for checks: a bar on its own).
  final int? lastStep;
  final math.Random _rng;
  final TuneSamples _samples;
  late final Convolver _conv;
  late final Compressor _comp;
  late final FeedbackEcho _echo;
  late final Float32List _curve;
  int _done = 0;
  late int _next;
  Float32List? _horn;

  final _drumsIn = _Acc(), _hatsIn = _Acc(), _duckIn = _Acc(), _reeseIn = _Acc(), _padIn = _Acc();
  final _arpIn = _Acc(), _master = _Acc(), _reverbIn = _Acc();
  final _drumsF = _Auto(16000);
  final _duck = _Auto(1);
  late final Biquad _drums = Biquad(BiquadType.lowpass, Param(16000), 0.7);
  final _hats = Biquad.fixed(BiquadType.highpass, 7000, 0.7);
  final _reeseLow = Biquad.fixed(BiquadType.highpass, 90, 0.7);
  final _padTone = Biquad.fixed(BiquadType.lowpass, 1700, 0.5);
  final _arpTone = Biquad.fixed(BiquadType.lowpass, 3200, 0.8);

  /// Notes started so far.
  int notes = 0;

  int _at(double t) => (t * sr).round();

  /// The next [n] samples (stereo).
  MusicChunk render(int n) {
    final until = startAt + (_done + n) / sr;
    for (; _next * djStep < until && _next <= (lastStep ?? _next); _next++) {
      _play(_next, _next * djStep - startAt);
    }
    final hats = _hats.process(_hatsIn.take(n), sr);
    final drums = _drumsIn.take(n);
    for (var i = 0; i < n; i++) {
      drums[i] += hats[i];
    }
    // The drums' filter moves bar by bar in the intro: coefficients every 32 samples.
    for (var at = 0; at < n; at += 32) {
      final end = math.min(n, at + 32);
      for (var i = at; i < end; i++) {
        _drumsF.step(_done + i, sr);
      }
      _drums.frequency.value = _drumsF.value;
      _drums.process(Float32List.sublistView(drums, at, end), sr);
    }
    final reese = _reeseLow.process(shape(_reeseIn.take(n), _curve), sr);
    final pad = _padTone.process(_padIn.take(n), sr);
    final duck = _duckIn.take(n);
    final rev = _reverbIn.take(n);
    for (var i = 0; i < n; i++) {
      final d = _duck.step(_done + i, sr);
      duck[i] = (duck[i] + reese[i] * 0.55 + pad[i]) * d;
      rev[i] += pad[i];
    }
    final arp = _arpTone.process(_arpIn.take(n), sr);
    final echoes = _echo.wet(arp);
    final wet = _conv.process(rev);
    final master = _master.take(n);
    final left = Float32List(n), right = Float32List(n);
    for (var i = 0; i < n; i++) {
      final m = master[i] + drums[i] + duck[i] + arp[i] + echoes[i];
      left[i] = m + wet[0][i] * 0.3;
      right[i] = m + wet[1][i] * 0.3;
    }
    _comp.process(left, right);
    for (var i = 0; i < n; i++) {
      final t = (_done + i) / sr;
      final fade = t >= 1.2 ? _djLevel : _djLevel * t / 1.2;
      left[i] *= fade;
      right[i] *= fade;
    }
    _done += n;
    return MusicChunk(left, right);
  }

  void _play(int k, double when) {
    final p = plan(k);
    final track = p.track, section = p.section, s = p.s, chord = p.chord;
    final part = section.part, bar = section.bar, second = section.second;
    double len(int n) => n * djStep;
    final at = _at(when);

    if (s == 0) {
      final f = part == Part.intro ? 500 * math.pow(24, bar / 15).toDouble() : 16000.0;
      _drumsF.target(at, f, 0.2);
    }
    if (p.kick > 0) _kick(at, p.kick);
    if (p.snare > 0) _snare(at, p.snare);
    if (p.hat > 0) _hat(at, p.hat * (0.75 + 0.25 * hash(k, 3)), false);
    if (p.openHat) _hat(at, 0.7, true);
    if (p.shaker > 0) _shaker(at, p.shaker);

    final padNotes = [
      for (final i in const [0, 2, 4, 6]) scaleNote(track.root + 24, chord + i),
    ];
    final twoBars = bar % 2 == 0 && s == 0;
    if (part == Part.intro || part == Part.breakdown) {
      if (twoBars) _pad(at, padNotes, len(32), part == Part.breakdown ? 1 : 0.8);
      if (part == Part.intro && bar >= 8 && s == 0) _sub(at, _subNote(track, chord), len(16));
    } else if (part == Part.build) {
      if (twoBars && bar < 6) _pad(at, padNotes, len(32), 0.6);
      if (s == 0) _riser(at, bar / section.bars, (bar + 1) / section.bars);
    } else if (part == Part.drop) {
      if (bar == 0 && s == 0) {
        _impact(at);
        if (!second && track.horn) {
          final h = _horn ??= renderHornDry(sr);
          _master.add(at + _at(djStep * 2), h);
          _reverbIn.add(at + _at(djStep * 2), h);
        }
      }
      if (twoBars) _pad(at, padNotes, len(32), 0.4);
      if (s == 0) _sub(at, _subNote(track, chord), len(16));
      final reese = scaleNote(track.root + 12, chord);
      if (track.bass == Bass.reese) {
        if (s == 0) _reese(at, reese, len(bar.isOdd ? 10 : 16), track.wah);
        if (s == 10 && bar.isOdd) _reese(at, reese + 12, len(6), track.wah.substring(5));
      } else {
        for (final (on, n, up) in const [(0, 3, 0), (3, 2, 0), (6, 3, 12), (10, 2, 0), (12, 3, 7)]) {
          if (on == s) _reese(at, reese + up, len(n), 'hl');
        }
      }
    }
    if ((part == Part.breakdown && bar >= 4) || (part == Part.drop && second)) {
      final i = track.arp[s];
      _arp(at, scaleNote(track.root + 48, chord + i * 2 - (i > 3 ? 7 : 0)), part == Part.drop ? 0.8 : 1);
    }
  }

  int _subNote(Track track, int chord) {
    final n = scaleNote(track.root, chord);
    return n > track.root + 6 ? n - 12 : n;
  }

  Float32List _noise(double seconds) => noise(sampleCount(seconds, sr), sr, _rng);

  void _kick(int at, double vel) {
    final n = sampleCount(0.4, sr);
    final f = Param(190)
      ..setValueAtTime(190, 0)
      ..exponentialRampToValueAtTime(55, 0.045)
      ..exponentialRampToValueAtTime(42, 0.25);
    _drumsIn.add(at, gain(osc(n, sr, Wave.sine, f), sr, _env(0.95 * vel, 0.002, 0.34)));
    final click = biquad(_noise(0.02), sr, BiquadType.highpass, 2500, 0.7);
    _drumsIn.add(at, gain(click, sr, _env(0.25 * vel, 0.001, 0.012)));
    _duck.set(at, 0.35);
    _duck.target(at + _at(0.02), 1, 0.07);
    notes++;
  }

  void _snare(int at, double vel) {
    final n = sampleCount(0.22, sr);
    final rattle = biquad(_noise(0.22), sr, BiquadType.highpass, 900, 0.7);
    final f = Param(230)
      ..setValueAtTime(230, 0)
      ..exponentialRampToValueAtTime(180, 0.06);
    mixInto(rattle, gain(osc(n, sr, Wave.triangle, f, stop: 0.14), sr, _env(0.4 * vel, 0.002, 0.1)));
    final g = gain(rattle, sr, _env(0.55 * vel, 0.002, 0.17));
    _drumsIn.add(at, g);
    if (vel > 0.5) _reverbIn.add(at, g);
    notes++;
  }

  void _hat(int at, double vel, bool open) {
    final h = _noise(open ? 0.3 : 0.06);
    _hatsIn.add(at, gain(h, sr, _env((open ? 0.12 : 0.16) * vel, 0.001, open ? 0.24 : 0.035)));
    notes++;
  }

  void _shaker(int at, double vel) {
    final s = biquad(_noise(0.05), sr, BiquadType.bandpass, 9000, 1.2);
    _drumsIn.add(at, gain(s, sr, _env(0.07 * vel, 0.006, 0.03)));
  }

  void _sub(int at, int midi, double len) {
    final n = sampleCount(len + 0.02, sr);
    final g = Param(0)
      ..setValueAtTime(0, 0)
      ..linearRampToValueAtTime(0.42, 0.02)
      ..setValueAtTime(0.42, len - 0.04)
      ..linearRampToValueAtTime(0, len);
    _duckIn.add(at, gain(osc(n, sr, Wave.sine, Param(mtof(midi))), sr, g));
    notes++;
  }

  /// Detuned saws through a resonant filter that opens and closes on the 8ths: the reese bass.
  void _reese(int at, int midi, double len, String wah) {
    final n = sampleCount(len + 0.02, sr);
    final f = Param(300);
    const eighth = djStep * 2;
    for (var i = 0; i * eighth < len; i++) {
      f.setTargetAtTime(wah[i % wah.length] == 'h' ? 1600 : 260, i * eighth, eighth * 0.3);
    }
    final saws = Float32List(n);
    for (final det in const [-17.0, 0.0, 17.0]) {
      mixInto(saws, osc(n, sr, Wave.sawtooth, Param(mtof(midi)), detune: Param(det), stop: len + 0.02));
    }
    biquadAuto(saws, sr, BiquadType.lowpass, f, 6);
    final g = Param(0)
      ..setValueAtTime(0, 0)
      ..linearRampToValueAtTime(0.3, 0.01)
      ..setValueAtTime(0.3, math.max(0.02, len - 0.03))
      ..linearRampToValueAtTime(0, len);
    _reeseIn.add(at, gain(saws, sr, g));
    notes++;
  }

  /// A slow, wide chord: two detuned saws a note.
  void _pad(int at, List<int> chord, double len, double level) {
    final n = sampleCount(len + 1, sr);
    final out = Float32List(n);
    for (final m in chord) {
      for (final det in const [-9.0, 9.0]) {
        mixInto(out, osc(n, sr, Wave.sawtooth, Param(mtof(m)), detune: Param(det)));
      }
    }
    final g = Param(0)
      ..setValueAtTime(0, 0)
      ..linearRampToValueAtTime(0.045 * level, 0.5)
      ..setValueAtTime(0.045 * level, len)
      ..linearRampToValueAtTime(0, len + 0.9);
    _padIn.add(at, gain(out, sr, g));
    notes++;
  }

  void _arp(int at, int midi, double level) {
    final o = osc(sampleCount(0.2, sr), sr, Wave.square, Param(mtof(midi)));
    _arpIn.add(at, gain(o, sr, _env(0.05 * level, 0.003, 0.16)));
    notes++;
  }

  /// One bar of the build's noise sweep, from [from] to [to] of the way through it.
  void _riser(int at, double from, double to) {
    double f(double p) => 300 * math.pow(28, p).toDouble();
    final bp = Param(300)
      ..setValueAtTime(f(from), 0)
      ..exponentialRampToValueAtTime(f(to), djBar);
    final g = Param(1)
      ..setValueAtTime(0.02 + 0.3 * from * from, 0)
      ..linearRampToValueAtTime(to >= 1 ? 0 : 0.02 + 0.3 * to * to, djBar);
    final r = gain(biquadAuto(_noise(djBar + 0.01), sr, BiquadType.bandpass, bp, 1.4), sr, g);
    _master.add(at, r);
    _reverbIn.add(at, r);
  }

  /// The drop lands: a crash and a boom.
  void _impact(int at) {
    final crash = gain(biquad(_noise(2.2), sr, BiquadType.highpass, 4500, 0.6), sr, _env(0.3, 0.004, 2));
    _master.add(at, crash);
    _reverbIn.add(at, crash);
    final f = Param(95)
      ..setValueAtTime(95, 0)
      ..exponentialRampToValueAtTime(30, 0.9);
    _master.add(at, gain(osc(sampleCount(1.3, sr), sr, Wave.sine, f), sr, _env(0.7, 0.005, 1.2)));
  }
}

/// The air horn: BAAP, bap bap, BAAAAAP, through its bandpass at its 0.9 (before the DJ's compressor).
Float32List renderHornDry(int sr) {
  final n = sampleCount(1.25, sr);
  final out = Float32List(n);
  for (final (t, len) in const [(0.0, 0.2), (0.26, 0.09), (0.4, 0.09), (0.55, 0.62)]) {
    final blast = Float32List(n);
    for (final (f, det) in const [(415.0, 0.0), (415.0, 14.0), (523.0, -8.0), (830.0, 6.0)]) {
      final fp = Param(f)
        ..setValueAtTime(f * 0.9, t)
        ..exponentialRampToValueAtTime(f, t + 0.06);
      mixInto(blast, osc(n, sr, Wave.sawtooth, fp, start: t, stop: t + len + 0.02, detune: Param(det)));
    }
    final env = Param(0)
      ..setValueAtTime(0, t)
      ..linearRampToValueAtTime(0.22, t + 0.015)
      ..setValueAtTime(0.22, t + len - 0.03)
      ..linearRampToValueAtTime(0, t + len);
    mixInto(out, gain(blast, sr, env));
  }
  return scale(biquad(out, sr, BiquadType.bandpass, 1300, 0.6), 0.9);
}

/// The air horn as someone at the booth blows it: dry, its reverb, and the DJ's compressor and level.
List<Float32List> renderHorn(int sr) {
  final dry = renderHornDry(sr);
  final room = TuneSamples(sr, math.Random(5)).room;
  final n = dry.length + sampleCount(1.2, sr);
  final input = Float32List(n)..setRange(0, dry.length, dry);
  final wet = Convolver(room, sr, block: 2048).process(input);
  final left = Float32List(n), right = Float32List(n);
  for (var i = 0; i < n; i++) {
    left[i] = input[i] + wet[0][i] * 0.3;
    right[i] = input[i] + wet[1][i] * 0.3;
  }
  Compressor(threshold: -16, knee: 8, ratio: 4, attack: 0.005, release: 0.12, sr: sr).process(left, right);
  return [scale(left, _djLevel), scale(right, _djLevel)];
}
