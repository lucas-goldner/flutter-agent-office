// The jukebox's own tunes: lo-fi beats synthesized with Web Audio, like the office's other sounds
// (see sound.dart). A tune is four bars of chords played on a warm electric piano over swung drums
// and a round bass, with a little melody, the crackle of an old record and a wobbly tape. It runs
// in 32-bar rounds so it breathes: the keys alone at first, then the beat, a melody, a breakdown.
//
// Every note follows from the tune and how far into it you are (score.dart), so everyone on the
// floor who starts from the same moment hears exactly the same bar.

import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import 'samples.dart';
import 'score.dart';
import 'web_audio.dart';

/// The tune's level after its compressor: at full volume, right at the jukebox, it peaks around 0.7.
const double _level = 0.75;

final math.Random _random = math.Random();

class TunePlayer {
  TunePlayer(this._ctx, web.AudioNode out, String id) : score = Score(id) {
    _clock = TuneClock(score);
    final ctx = _ctx;
    final b = _buffers(ctx);

    _fade = ctx.createGain();
    _fade.gain.setValueAtTime(0, ctx.currentTime);
    _fade.gain.linearRampToValueAtTime(_level, ctx.currentTime + 1.5);
    _fade.connect(out);
    // Everything goes through a dull filter and a soft compressor, like an old sampler.
    final comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -20;
    comp.ratio.value = 3;
    comp.attack.value = 0.01;
    comp.release.value = 0.2;
    _dry = ctx.createGain();
    _dry.gain.value = 0.8;
    _dry.to(biquad(ctx, 'lowpass', 5200, 0.5)).to(comp).to(_fade);

    final conv = ctx.createConvolver();
    conv.buffer = b.room;
    final wet = ctx.createGain();
    wet.gain.value = 0.35;
    conv.to(wet).to(_dry);
    _reverb = conv;

    // The keys wobble in volume a little, like a Rhodes' tremolo.
    final trem = ctx.createGain();
    trem.gain.value = 0.85;
    _lfo(3.2, 0.15).connect(trem.gain);
    final keysTone = biquad(ctx, 'lowpass', 2400, 0.6);
    keysTone.to(trem).to(_dry);
    trem.connect(_reverb);
    _keysBus = keysTone;
    final melodyTone = biquad(ctx, 'lowpass', 3000, 0.7);
    melodyTone.connect(_dry);
    melodyTone.connect(_reverb);
    _melodyBus = melodyTone;
    _bassBus = biquad(ctx, 'lowpass', 420, 0.8);
    _bassBus.connect(_dry);
    _hatBus = biquad(ctx, 'highpass', 6500, 0.7);
    _hatBus.connect(_dry);

    _wobble = _lfo(0.37, 9);
    _vibrato = _lfo(5.2, 7);

    // The needle in the groove: crackle and a faint hiss, the whole time.
    final crackle = ctx.createBufferSource();
    crackle.buffer = b.crackle;
    crackle.loop = true;
    final crackleG = ctx.createGain();
    crackleG.gain.value = 0.05;
    crackle.to(biquad(ctx, 'highpass', 900, 0.7)).to(crackleG).to(_fade);
    crackle.start();
    _loops.add(crackle);
  }

  final web.BaseAudioContext _ctx;
  final Score score;
  late final TuneClock _clock;
  late final web.GainNode _fade;
  late final web.GainNode _dry;
  late final web.AudioNode _keysBus;
  late final web.AudioNode _melodyBus;
  late final web.AudioNode _bassBus;
  late final web.AudioNode _hatBus;
  late final web.AudioNode _reverb;

  /// Slow pitch drift on everything tuned, like a stretched tape.
  late final web.GainNode _wobble;
  late final web.GainNode _vibrato;
  final List<web.AudioScheduledSourceNode> _loops = [];
  bool _stopped = false;

  /// Notes scheduled so far, for quick checks.
  int notes = 0;

  /// Schedules what's coming up. `at` is how far into the tune it is now, in seconds.
  void tick(double at) {
    // A suspended context's clock stands still: notes scheduled on it would all come out at once.
    if (_stopped || _ctx.state != 'running') return;
    for (final (k, time) in _clock.due(at, _ctx.currentTime)) {
      _play(k, time);
    }
  }

  /// Schedules the 16ths `from` up to `until` straight away, starting at `start` on the audio clock,
  /// whatever state the context is in: for rendering a bar into an OfflineAudioContext.
  void prerender(int from, int until, [double start = 0]) {
    final t0 = score.stepTime(from);
    for (var k = from; k < until; k++) {
      _play(k, start + score.stepTime(k) - t0);
    }
  }

  /// 1 on each beat, falling to 0 before the next, for the jukebox's lights.
  double beat(double at) => score.beat(at);

  /// Fades out and lets go of everything.
  void stop() {
    if (_stopped) return;
    _stopped = true;
    final now = _ctx.currentTime;
    _fade.gain.cancelScheduledValues(now);
    _fade.gain.setValueAtTime(_fade.gain.value, now);
    _fade.gain.linearRampToValueAtTime(0, now + 0.4);
    Timer(const Duration(milliseconds: 1500), () {
      for (final s in _loops) {
        s.stop();
      }
      _fade.disconnect();
    });
  }

  void _play(int k, double when) {
    for (final e in score.eventsAt(k)) {
      switch (e.voice) {
        case Voice.kick:
          _kick(when, e.vel);
        case Voice.snare:
          _snare(when, e.vel);
        case Voice.hat:
          _hat(when, e.vel);
        case Voice.bass:
          _bass(when, e.midi, e.len);
        case Voice.key:
          _key(when + e.delay, e.midi, e.len, e.vel);
        case Voice.lead:
          _lead(when, e.midi, e.len);
      }
    }
  }

  // ---- Instruments ------------------------------------------------------------------------------

  void _kick(double when, double vel) {
    final ctx = _ctx;
    final o = ctx.createOscillator();
    o.frequency.setValueAtTime(115, when);
    o.frequency.exponentialRampToValueAtTime(44, when + 0.12);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(0.85 * vel, when + 0.006);
    g.gain.exponentialRampToValueAtTime(0.0001, when + 0.42);
    o.to(g).to(_dry);
    o.start(when);
    o.stop(when + 0.45);
    notes++;
  }

  void _snare(double when, double vel) {
    final ctx = _ctx;
    final n = ctx.createBufferSource();
    n.buffer = _buffers(ctx).noise;
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(0.32 * vel, when + 0.004);
    g.gain.exponentialRampToValueAtTime(0.0001, when + 0.22);
    n.to(biquad(ctx, 'bandpass', 1900, 0.9)).to(g);
    // A little body under the rattle.
    final o = ctx.createOscillator();
    o.type = 'triangle';
    o.frequency.setValueAtTime(190, when);
    o.frequency.exponentialRampToValueAtTime(140, when + 0.08);
    final og = ctx.createGain();
    og.gain.setValueAtTime(0.0001, when);
    og.gain.exponentialRampToValueAtTime(0.25 * vel, when + 0.003);
    og.gain.exponentialRampToValueAtTime(0.0001, when + 0.1);
    o.to(og).to(g);
    g.connect(_dry);
    g.connect(_reverb);
    n.start(when, _random.nextDouble() * 2);
    n.stop(when + 0.25);
    o.start(when);
    o.stop(when + 0.12);
    notes++;
  }

  void _hat(double when, double vel) {
    final ctx = _ctx;
    final n = ctx.createBufferSource();
    n.buffer = _buffers(ctx).noise;
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(0.13 * vel, when + 0.002);
    g.gain.exponentialRampToValueAtTime(0.0001, when + 0.045);
    n.to(g).to(_hatBus);
    n.start(when, _random.nextDouble() * 2);
    n.stop(when + 0.06);
    notes++;
  }

  void _bass(double when, int midi, double len) {
    final ctx = _ctx;
    final f = mtof(midi);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0, when);
    g.gain.linearRampToValueAtTime(0.34, when + 0.012);
    g.gain.setTargetAtTime(0.24, when + 0.012, 0.3);
    g.gain.setTargetAtTime(0, when + len, 0.05);
    for (final (type, mul, lvl) in const [('sine', 1.0, 1.0), ('triangle', 2.0, 0.18)]) {
      final o = ctx.createOscillator();
      o.type = type;
      o.frequency.value = f * mul;
      final og = ctx.createGain();
      og.gain.value = lvl;
      o.to(og).to(g);
      o.start(when);
      o.stop(when + len + 0.4);
    }
    g.connect(_bassBus);
    notes++;
  }

  /// An electric piano note: a sine, brightened for a moment by another at the same pitch.
  void _key(double when, int midi, double len, double vel) {
    final ctx = _ctx;
    final f = mtof(midi);
    final car = ctx.createOscillator();
    car.frequency.value = f;
    car.detune.value = (hash(midi, 5) - 0.5) * 8;
    final mod = ctx.createOscillator();
    mod.frequency.value = f;
    final depth = ctx.createGain();
    depth.gain.setValueAtTime(f * 1.4 * vel, when);
    depth.gain.exponentialRampToValueAtTime(f * 0.12, when + 0.5);
    mod.to(depth).connect(car.frequency);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0, when);
    g.gain.linearRampToValueAtTime(0.085 * vel, when + 0.006);
    g.gain.setTargetAtTime(0.035 * vel, when + 0.006, 0.5);
    g.gain.setTargetAtTime(0, when + len, 0.12);
    car.to(g).to(_keysBus);
    _tape(car, _wobble);
    final end = when + len + 0.8;
    car.start(when);
    mod.start(when);
    car.stop(end);
    mod.stop(end);
    notes++;
  }

  void _lead(double when, int midi, double len) {
    final ctx = _ctx;
    final o = ctx.createOscillator();
    o.type = 'triangle';
    o.frequency.value = mtof(midi);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0, when);
    g.gain.linearRampToValueAtTime(0.075, when + 0.03);
    g.gain.setTargetAtTime(0.05, when + 0.03, 0.4);
    g.gain.setTargetAtTime(0, when + len, 0.1);
    o.to(g).to(_melodyBus);
    _tape(o, _wobble);
    _tape(o, _vibrato);
    o.start(when);
    o.stop(when + len + 0.6);
    notes++;
  }

  /// Detunes `o` along with an LFO while it plays, then lets go of it.
  void _tape(web.OscillatorNode o, web.GainNode lfo) {
    lfo.connect(o.detune);
    o.addEventListener('ended', ((web.Event _) => lfo.disconnect(o.detune)).toJS, web.AddEventListenerOptions(once: true));
  }

  /// A sine LFO, `depth` either side of zero.
  web.GainNode _lfo(double freq, double depth) {
    final o = _ctx.createOscillator();
    o.frequency.value = freq;
    final g = _ctx.createGain();
    g.gain.value = depth;
    o.connect(g);
    o.start();
    _loops.add(o);
    return g;
  }
}

// ---- Plumbing --------------------------------------------------------------------------------------

class _Buffers {
  _Buffers(this.noise, this.crackle, this.room);

  final web.AudioBuffer noise;
  final web.AudioBuffer crackle;

  /// A small, dark room to put the keys and snare in.
  final web.AudioBuffer room;
}

// Made once per context (there's one live context, and the odd offline one for checks).
web.BaseAudioContext? _madeFor;
_Buffers? _made;

_Buffers _buffers(web.BaseAudioContext ctx) {
  final made = _made;
  if (made != null && identical(_madeFor, ctx)) return made;
  final s = TuneSamples(ctx.sampleRate.round(), _random);
  final b = _Buffers(audioBuffer(ctx, [s.noise]), audioBuffer(ctx, [s.crackle]), audioBuffer(ctx, s.room));
  _madeFor = ctx;
  _made = b;
  return b;
}
