// The DJ on the rooftop: an endless drum and bass set, synthesized with Web Audio like the jukebox's
// tunes (music.dart). A port of dnb.ts's DjPlayer. What plays when is dnb_score.dart, the pure half,
// so everyone up there hears the same bar at the same moment.

import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import 'dnb_score.dart';
import 'music.dart' show tuneBuffers;
import 'score.dart' show hash, mtof;
import 'web_audio.dart';

/// How far ahead notes are scheduled (s): enough to ride out a busy frame or a timer that runs late.
const double _lookahead = 1.1;

/// The set's level after its compressor.
const double _level = 0.9;

final math.Random _random = math.Random();

class DjPlayer {
  DjPlayer(this._ctx, web.AudioNode out) {
    final ctx = _ctx;
    _fade = ctx.createGain();
    _fade.gain.setValueAtTime(0, ctx.currentTime);
    _fade.gain.linearRampToValueAtTime(_level, ctx.currentTime + 1.2);
    _fade.connect(out);
    _master = ctx.createDynamicsCompressor();
    _master.threshold.value = -16;
    _master.knee.value = 8;
    _master.ratio.value = 4;
    _master.attack.value = 0.005;
    _master.release.value = 0.12;
    _master.connect(_fade);

    final bufs = tuneBuffers(ctx);
    _noise = bufs.noise;
    final room = ctx.createConvolver();
    room.buffer = bufs.room;
    final wet = ctx.createGain();
    wet.gain.value = 0.3;
    room.to(wet).to(_master);
    _reverb = room;

    _drums = biquad(ctx, 'lowpass', 16000, 0.7);
    _drums.connect(_master);
    _hats = biquad(ctx, 'highpass', 7000, 0.7);
    _hats.connect(_drums);

    _duck = ctx.createGain();
    _duck.connect(_master);
    // The reese growls through a little distortion, with the lows left to the sub.
    final drive = ctx.createWaveShaper();
    drive.curve = driveCurve(2.2).toJS;
    drive.oversample = '2x';
    final low = biquad(ctx, 'highpass', 90, 0.7);
    final reeseLevel = ctx.createGain();
    reeseLevel.gain.value = 0.55;
    drive.to(low).to(reeseLevel).to(_duck);
    _reeseBus = drive;

    final padTone = biquad(ctx, 'lowpass', 1700, 0.5);
    padTone.connect(_duck);
    padTone.connect(room);
    _padBus = padTone;

    // The arpeggio echoes on the dotted 8th.
    final arpTone = biquad(ctx, 'lowpass', 3200, 0.8);
    final echo = ctx.createDelay(1);
    echo.delayTime.value = djStep * 3;
    final feedback = ctx.createGain();
    feedback.gain.value = 0.38;
    final echoLevel = ctx.createGain();
    echoLevel.gain.value = 0.45;
    arpTone.connect(_master);
    arpTone.connect(echo);
    echo.to(feedback).to(echo);
    echo.to(echoLevel).to(_master);
    _arpBus = arpTone;
  }

  final web.BaseAudioContext _ctx;

  /// Audio-clock time minus set time.
  double _offset = double.nan;

  /// The next 16th to schedule.
  int _next = -1;
  late final web.GainNode _fade;
  late final web.DynamicsCompressorNode _master;
  late final web.BiquadFilterNode _drums;
  late final web.AudioNode _hats;

  /// Ducks the bass and the pads on every kick, so the kick punches through.
  late final web.GainNode _duck;
  late final web.AudioNode _reeseBus;
  late final web.AudioNode _padBus;
  late final web.AudioNode _arpBus;
  late final web.AudioNode _reverb;
  late final web.AudioBuffer _noise;
  bool _stopped = false;

  /// Notes scheduled so far, for quick checks.
  int notes = 0;

  /// Schedules what's coming up. [at] is how far into the set it is now (see djTime).
  void tick(double at) {
    final ctx = _ctx;
    // A suspended context's clock stands still: notes scheduled on it would all come out at once.
    if (_stopped || ctx.state != 'running') return;
    final offset = ctx.currentTime - at;
    final drift = (offset - _offset).abs();
    if (!(drift < 0.03)) {
      _offset = offset;
      // A jump (a suspended context, a computer waking up, the office's clock arriving): pick up from now.
      if (!(drift < 0.5)) _next = -1;
    }
    if (_next < 0) _next = (at / djStep).ceil();
    final until = at + _lookahead;
    for (; _next * djStep < until; _next++) {
      final t = _next * djStep;
      if (t >= at - 0.02) _play(_next, math.max(ctx.currentTime, t + _offset));
    }
  }

  /// Schedules the 16ths [from] up to [until] straight away, from [start] on the audio clock: for
  /// rendering into an OfflineAudioContext.
  void prerender(int from, int until, [double start = 0]) {
    for (var k = from; k < until; k++) {
      _play(k, start + (k - from) * djStep);
    }
  }

  /// Fades out and lets go of everything.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    final now = _ctx.currentTime;
    _fade.gain.cancelScheduledValues(now);
    _fade.gain.setValueAtTime(_fade.gain.value, now);
    _fade.gain.linearRampToValueAtTime(0, now + 0.5);
    Timer(const Duration(milliseconds: 2500), () => _fade.disconnect());
  }

  /// The air horn, as the DJ (or whoever's at the booth) lets rip: BAAP, bap bap, BAAAAAP.
  void horn([double? when]) {
    final ctx = _ctx;
    final w0 = when ?? ctx.currentTime;
    final out = biquad(ctx, 'bandpass', 1300, 0.6);
    final g = ctx.createGain();
    g.gain.value = 0.9;
    out.to(g).to(_master);
    g.connect(_reverb);
    for (final (t, len) in const [(0.0, 0.2), (0.26, 0.09), (0.4, 0.09), (0.55, 0.62)]) {
      final env = ctx.createGain();
      final w = w0 + t;
      env.gain.setValueAtTime(0, w);
      env.gain.linearRampToValueAtTime(0.22, w + 0.015);
      env.gain.setValueAtTime(0.22, w + len - 0.03);
      env.gain.linearRampToValueAtTime(0, w + len);
      env.connect(out);
      for (final (f, det) in const [(415.0, 0.0), (415.0, 14.0), (523.0, -8.0), (830.0, 6.0)]) {
        final o = ctx.createOscillator();
        o.type = 'sawtooth';
        o.detune.value = det;
        // Each blast scoops up into the note.
        o.frequency.setValueAtTime(f * 0.9, w);
        o.frequency.exponentialRampToValueAtTime(f, w + 0.06);
        o.connect(env);
        o.start(w);
        o.stop(w + len + 0.02);
      }
    }
    notes++;
  }

  void _play(int k, double when) {
    final p = plan(k);
    final track = p.track, section = p.section, s = p.s, chord = p.chord;
    final part = section.part, bar = section.bar, second = section.second;
    double len(int n) => n * djStep;

    // The drums, and how muffled they are: the intro's filter opens bar by bar.
    if (s == 0) {
      final f = part == Part.intro ? 500 * math.pow(24, bar / 15).toDouble() : 16000.0;
      _drums.frequency.setTargetAtTime(f, when, 0.2);
    }
    if (p.kick > 0) _kick(when, p.kick);
    if (p.snare > 0) _snare(when, p.snare);
    if (p.hat > 0) _hat(when, p.hat * (0.75 + 0.25 * hash(k, 3)), false);
    if (p.openHat) _hat(when, 0.7, true);
    if (p.shaker > 0) _shaker(when, p.shaker);

    final padNotes = [
      for (final i in const [0, 2, 4, 6]) scaleNote(track.root + 24, chord + i),
    ];
    final twoBars = bar % 2 == 0 && s == 0;
    if (part == Part.intro || part == Part.breakdown) {
      if (twoBars) _pad(when, padNotes, len(32), part == Part.breakdown ? 1 : 0.8);
      // The sub comes in halfway through the intro.
      if (part == Part.intro && bar >= 8 && s == 0) _sub(when, _subNote(track, chord), len(16));
    } else if (part == Part.build) {
      if (twoBars && bar < 6) _pad(when, padNotes, len(32), 0.6);
      if (s == 0) _riser(when, bar / section.bars, (bar + 1) / section.bars);
    } else if (part == Part.drop) {
      if (bar == 0 && s == 0) {
        _impact(when);
        if (!second && track.horn) horn(when + djStep * 2);
      }
      if (twoBars) _pad(when, padNotes, len(32), 0.4);
      if (s == 0) _sub(when, _subNote(track, chord), len(16));
      final reese = scaleNote(track.root + 12, chord);
      if (track.bass == Bass.reese) {
        // A long growl across the bar, jumping up an octave for the last few 16ths every other bar.
        if (s == 0) _reese(when, reese, len(bar.isOdd ? 10 : 16), track.wah);
        if (s == 10 && bar.isOdd) _reese(when, reese + 12, len(6), track.wah.substring(5));
      } else {
        for (final (at, n, up) in const [(0, 3, 0), (3, 2, 0), (6, 3, 12), (10, 2, 0), (12, 3, 7)]) {
          if (at == s) _reese(when, reese + up, len(n), 'hl');
        }
      }
    }
    // The arpeggio: through the breakdown once it's got going, and over the second drop.
    if ((part == Part.breakdown && bar >= 4) || (part == Part.drop && second)) {
      final i = track.arp[s];
      _arp(when, scaleNote(track.root + 48, chord + i * 2 - (i > 3 ? 7 : 0)), part == Part.drop ? 0.8 : 1);
    }
  }

  int _subNote(Track track, int chord) {
    final n = scaleNote(track.root, chord);
    return n > track.root + 6 ? n - 12 : n;
  }

  // ---- Instruments ------------------------------------------------------------------------------

  web.AudioBufferSourceNode _noiseAt(double when, double until) {
    final n = _ctx.createBufferSource();
    n.buffer = _noise;
    n.start(when, _random.nextDouble() * 2);
    n.stop(until);
    return n;
  }

  web.GainNode _env(double when, double peak, double attack, double decay) {
    final g = _ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(peak, when + attack);
    g.gain.exponentialRampToValueAtTime(0.0001, when + attack + decay);
    return g;
  }

  void _kick(double when, double vel) {
    final ctx = _ctx;
    final o = ctx.createOscillator();
    o.frequency.setValueAtTime(190, when);
    o.frequency.exponentialRampToValueAtTime(55, when + 0.045);
    o.frequency.exponentialRampToValueAtTime(42, when + 0.25);
    o.to(_env(when, 0.95 * vel, 0.002, 0.34)).to(_drums);
    o.start(when);
    o.stop(when + 0.4);
    // The beater's click.
    _noiseAt(
      when,
      when + 0.02,
    ).to(biquad(ctx, 'highpass', 2500, 0.7)).to(_env(when, 0.25 * vel, 0.001, 0.012)).to(_drums);
    // Everything else ducks out of its way.
    _duck.gain.setValueAtTime(0.35, when);
    _duck.gain.setTargetAtTime(1, when + 0.02, 0.07);
    notes++;
  }

  void _snare(double when, double vel) {
    final ctx = _ctx;
    final g = _env(when, 0.55 * vel, 0.002, 0.17);
    _noiseAt(when, when + 0.22).to(biquad(ctx, 'highpass', 900, 0.7)).to(biquad(ctx, 'peaking', 2400, 1)).to(g);
    final o = ctx.createOscillator();
    o.type = 'triangle';
    o.frequency.setValueAtTime(230, when);
    o.frequency.exponentialRampToValueAtTime(180, when + 0.06);
    o.to(_env(when, 0.4 * vel, 0.002, 0.1)).to(g);
    o.start(when);
    o.stop(when + 0.14);
    g.connect(_drums);
    if (vel > 0.5) g.connect(_reverb);
    notes++;
  }

  void _hat(double when, double vel, bool open) {
    _noiseAt(
      when,
      when + (open ? 0.3 : 0.06),
    ).to(_env(when, (open ? 0.12 : 0.16) * vel, 0.001, open ? 0.24 : 0.035)).to(_hats);
    notes++;
  }

  void _shaker(double when, double vel) {
    _noiseAt(
      when,
      when + 0.05,
    ).to(biquad(_ctx, 'bandpass', 9000, 1.2)).to(_env(when, 0.07 * vel, 0.006, 0.03)).to(_drums);
  }

  /// A deep sine under everything, for the whole bar.
  void _sub(double when, int midi, double len) {
    final ctx = _ctx;
    final o = ctx.createOscillator();
    o.frequency.value = mtof(midi);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0, when);
    g.gain.linearRampToValueAtTime(0.42, when + 0.02);
    g.gain.setValueAtTime(0.42, when + len - 0.04);
    g.gain.linearRampToValueAtTime(0, when + len);
    o.to(g).to(_duck);
    o.start(when);
    o.stop(when + len + 0.02);
    notes++;
  }

  /// Detuned saws through a resonant filter that opens and closes on the 8ths: the reese bass.
  void _reese(double when, int midi, double len, String wah) {
    final ctx = _ctx;
    final lp = biquad(ctx, 'lowpass', 300, 6);
    const eighth = djStep * 2;
    for (var i = 0; i * eighth < len; i++) {
      lp.frequency.setTargetAtTime(wah[i % wah.length] == 'h' ? 1600 : 260, when + i * eighth, eighth * 0.3);
    }
    final g = ctx.createGain();
    g.gain.setValueAtTime(0, when);
    g.gain.linearRampToValueAtTime(0.3, when + 0.01);
    g.gain.setValueAtTime(0.3, when + math.max(0.02, len - 0.03));
    g.gain.linearRampToValueAtTime(0, when + len);
    lp.to(g).to(_reeseBus);
    for (final det in const [-17.0, 0.0, 17.0]) {
      final o = ctx.createOscillator();
      o.type = 'sawtooth';
      o.frequency.value = mtof(midi);
      o.detune.value = det;
      o.connect(lp);
      o.start(when);
      o.stop(when + len + 0.02);
    }
    notes++;
  }

  /// A slow, wide chord: two detuned saws a note.
  void _pad(double when, List<int> chord, double len, double level) {
    final ctx = _ctx;
    final g = ctx.createGain();
    g.gain.setValueAtTime(0, when);
    g.gain.linearRampToValueAtTime(0.045 * level, when + 0.5);
    g.gain.setValueAtTime(0.045 * level, when + len);
    g.gain.linearRampToValueAtTime(0, when + len + 0.9);
    g.connect(_padBus);
    for (final m in chord) {
      for (final det in const [-9.0, 9.0]) {
        final o = ctx.createOscillator();
        o.type = 'sawtooth';
        o.frequency.value = mtof(m);
        o.detune.value = det;
        o.connect(g);
        o.start(when);
        o.stop(when + len + 1);
      }
    }
    notes++;
  }

  void _arp(double when, int midi, double level) {
    final o = _ctx.createOscillator();
    o.type = 'square';
    o.frequency.value = mtof(midi);
    o.to(_env(when, 0.05 * level, 0.003, 0.16)).to(_arpBus);
    o.start(when);
    o.stop(when + 0.2);
    notes++;
  }

  /// One bar of the build's noise sweep, from [from] to [to] of the way through it.
  void _riser(double when, double from, double to) {
    final ctx = _ctx;
    final bp = biquad(ctx, 'bandpass', 300, 1.4);
    double f(double p) => 300 * math.pow(28, p).toDouble();
    bp.frequency.setValueAtTime(f(from), when);
    bp.frequency.exponentialRampToValueAtTime(f(to), when + djBar);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.02 + 0.3 * from * from, when);
    g.gain.linearRampToValueAtTime(to >= 1 ? 0 : 0.02 + 0.3 * to * to, when + djBar);
    _noiseAt(when, when + djBar + 0.01).to(bp).to(g).to(_master);
    g.connect(_reverb);
  }

  /// The drop lands: a crash and a boom.
  void _impact(double when) {
    final ctx = _ctx;
    final crash = _env(when, 0.3, 0.004, 2);
    _noiseAt(when, when + 2.2).to(biquad(ctx, 'highpass', 4500, 0.6)).to(crash).to(_master);
    crash.connect(_reverb);
    final o = ctx.createOscillator();
    o.frequency.setValueAtTime(95, when);
    o.frequency.exponentialRampToValueAtTime(30, when + 0.9);
    o.to(_env(when, 0.7, 0.005, 1.2)).to(_master);
    o.start(when);
    o.stop(when + 1.3);
  }
}
