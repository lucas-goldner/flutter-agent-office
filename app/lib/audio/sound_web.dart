// Office sounds, synthesized with Web Audio so there are no audio files to ship: the room's air and a
// humming fridge, workers typing while they work, footsteps, the coffee machine, birds outside the
// windows by day and crickets at night, rain and thunder, the odd rustle or phone, the gong, the dog
// barking, and the dings when a worker needs you. And the lounge jukebox, whose tunes are in music.dart.
//
// Everything goes through one master gain that Settings turns down or mutes. Voice chat doesn't, and
// the jukebox has a volume of its own.
//
// Browsers only allow audio after a click or key press: the AudioContext is made (or resumed) by
// unlock(), which runs on the page's first pointerdown or keydown, and whenever a ding or the gong
// wants to be heard.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import 'package:office_shared/jukebox.dart' show jukeboxStream;
import 'package:office_shared/layout.dart' show desks;
import 'package:office_shared/layout.dart' as lay show Cabinet;
import 'package:office_shared/protocol.dart' show GongWhy;
import '../state/store.dart' show nowMs;
import 'music.dart';
import 'samples.dart';
import 'sound_model.dart';
import 'web_audio.dart';

export 'sound_model.dart' show Ding, DogSounds, JukeboxPlay, SoundListener, StepKind;

final math.Random _rng = math.Random();
double _rand(double a, double b) => a + _rng.nextDouble() * (b - a);
int _randInt(int a, int b) => _rand(a.toDouble(), b + 1.0).floor();
T _pick<T>(List<T> xs) => xs[(_rng.nextDouble() * xs.length).floor()];

class OfficeSound implements DogSounds {
  /// Listens for the first click or key press to start audio, and for the tab hiding.
  OfficeSound({double Function()? clock}) : _now = clock ?? nowMs, _offline = false {
    final unlock = ((web.Event _) => this.unlock()).toJS;
    final visibility = ((web.Event _) => _applyVisibility()).toJS;
    final capture = web.AddEventListenerOptions(capture: true);
    web.window.addEventListener('pointerdown', unlock, capture);
    web.window.addEventListener('keydown', unlock, capture);
    web.document.addEventListener('visibilitychange', visibility);
    _unlisten = () {
      web.window.removeEventListener('pointerdown', unlock, web.EventListenerOptions(capture: true));
      web.window.removeEventListener('keydown', unlock, web.EventListenerOptions(capture: true));
      web.document.removeEventListener('visibilitychange', visibility);
    };
  }

  /// Plays into `ctx` (an OfflineAudioContext) straight away, for rendering sounds in checks. No
  /// listeners, and nothing that waits for the clock to run (update() does nothing).
  OfficeSound.offline(web.OfflineAudioContext ctx, {double Function()? clock}) : _now = clock ?? nowMs, _offline = true {
    _start(ctx);
  }

  final double Function() _now;
  final bool _offline;
  void Function()? _unlisten;

  web.BaseAudioContext? _ctx;
  late web.GainNode _master;

  /// The room itself; it goes quiet while the tab is hidden.
  late web.GainNode _ambience;

  /// Worker dings, which you still want to hear from another tab.
  late web.GainNode _alerts;
  late web.AnalyserNode _analyser;
  late _Buffers _buf;
  double _volume = 0.7;
  bool _muted = false;
  final Map<String, Typist<web.PannerNode>> _typists = {};
  _Fridge? _fridge;
  double _nextBird = 0;
  double _nextCricket = 0;
  double _nextPhone = 0;
  double _nextFidget = 0;

  /// Outside: how hard it's raining (0–1) and how dark it is (1 at night).
  double _rain = 0;
  double _night = 0;
  ({web.GainNode gain, web.BiquadFilterNode tone})? _rainNodes;
  double _nextRain = 0;
  double _nextDrip = 0;
  SoundListener _listener = const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1);
  // The jukebox: from the cabinet, through a filter that muffles it from across the room, to your own volume.
  late web.PannerNode _musicIn;
  late web.BiquadFilterNode _musicTone;
  double _musicCutoff = 16000;
  late web.GainNode _musicBus;
  late web.AnalyserNode _musicMeter;
  double _musicVolume = 0.5;
  bool _musicMuted = false;
  JukeboxPlay? _jukebox;
  TunePlayer? _tune;
  web.HTMLAudioElement? _stream;
  Timer? _musicTimer;

  /// A stream that won't play here.
  void Function(String text)? onMusicError;

  /// How many of each sound have played, for quick checks.
  final Map<String, int> played = {};

  /// Stops listening for the page's clicks and keys (the context itself lives on with the page).
  void dispose() {
    _unlisten?.call();
    _unlisten = null;
    _musicTimer?.cancel();
  }

  /// Volume is 0–1; muted silences everything without losing the level.
  void setVolume(double volume, bool muted) {
    _volume = volume.clamp(0, 1).toDouble();
    _muted = muted;
    _applyVolume();
  }

  /// The weather outside (see world/sky), every frame.
  void setWeather(double rain, double night) {
    _rain = rain;
    _night = night;
  }

  /// Output level (RMS) right now, for headless checks.
  double level() => _ctx == null ? 0 : analyserRms(_analyser);

  /// The jukebox's level (RMS) where you stand, after your music volume. A stream doesn't show here.
  double musicLevel() => _ctx == null ? 0 : analyserRms(_musicMeter);

  /// The context's state ('running', 'suspended', 'closed'), or 'locked' before audio has started.
  String get state => _ctx?.state ?? 'locked';

  /// Starts audio, or resumes it. Call it from a user gesture (the constructor already listens for the
  /// page's first pointerdown and keydown).
  void unlock() {
    final ctx = _ctx;
    if (ctx != null) {
      if (ctx.state == 'suspended' && !_offline) quietly((ctx as web.AudioContext).resume());
      // A ding can start audio before you've touched the page, when a stream isn't allowed to play yet.
      final s = _stream;
      if (s != null && s.paused) quietly(s.play());
      return;
    }
    if (_offline) return;
    final web.AudioContext live;
    try {
      live = web.AudioContext();
    } catch (_) {
      return; // no audio here
    }
    _start(live);
    quietly(live.resume());
  }

  void _start(web.BaseAudioContext ctx) {
    _ctx = ctx;
    _buf = _Buffers(ctx);
    // A gentle compressor, so a room full of typing never clips.
    final comp = ctx.createDynamicsCompressor();
    comp.threshold.value = -14;
    comp.knee.value = 12;
    comp.ratio.value = 4;
    comp.attack.value = 0.004;
    comp.release.value = 0.25;
    _analyser = ctx.createAnalyser();
    _analyser.fftSize = 2048;
    _master = ctx.createGain();
    _master.gain.value = 0;
    _master.to(comp).to(ctx.destination);
    comp.connect(_analyser);
    _ambience = ctx.createGain();
    _ambience.connect(_master);
    _alerts = ctx.createGain();
    _alerts.connect(_master);
    // The jukebox skips the master (it has its own volume) and keeps playing while the tab is hidden.
    _musicIn = _panner(jukeboxAt, musicRef, musicRolloff);
    _musicTone = biquad(ctx, 'lowpass', 16000, 0.5);
    _musicBus = ctx.createGain();
    _musicBus.gain.value = 0;
    _musicMeter = ctx.createAnalyser();
    _musicMeter.fftSize = 2048;
    _musicIn.to(_musicTone).to(_musicBus).to(ctx.destination);
    _musicBus.connect(_musicMeter);
    _applyVolume();
    _applyMusicVolume();
    _applyJukebox();
    _applyVisibility();
    _startRoomTone();
    _startFridge();
    final now = ctx.currentTime;
    _nextBird = now + _rand(5, 15);
    _nextCricket = now + _rand(2, 6);
    _nextPhone = now + _rand(60, 150);
    _nextFidget = now + _rand(8, 20);
  }

  void _applyVolume() {
    final ctx = _ctx;
    if (ctx == null) return;
    // Squared, so the slider feels even to the ear.
    final g = _muted ? 0.0 : _volume * _volume;
    _master.gain.setTargetAtTime(g, ctx.currentTime, 0.04);
  }

  bool get _hidden => !_offline && web.document.hidden;

  void _applyVisibility() {
    final ctx = _ctx;
    if (ctx == null) return;
    if (!_hidden && ctx.state == 'suspended' && !_offline) quietly((ctx as web.AudioContext).resume());
    _ambience.gain.setTargetAtTime(_hidden ? 0 : 1, ctx.currentTime, 0.15);
  }

  void _count(String what) => played[what] = (played[what] ?? 0) + 1;

  // ---- Every frame -------------------------------------------------------------------------------

  /// Moves your ears and schedules whatever the room does next.
  void update(SoundListener l) {
    final ctx = _ctx;
    if (ctx == null || ctx.state != 'running') return;
    _listener = l;
    // Level the facing, so looking straight down never lines it up with "up".
    final h = math.sqrt(l.fx * l.fx + l.fz * l.fz);
    final len = h == 0 ? 1.0 : h;
    final lis = ctx.listener;
    if ((lis as JSObject).has('positionX')) {
      lis.positionX.value = l.x;
      lis.positionY.value = l.y;
      lis.positionZ.value = l.z;
      lis.forwardX.value = l.fx / len;
      lis.forwardY.value = 0;
      lis.forwardZ.value = l.fz / len;
      lis.upX.value = 0;
      lis.upY.value = 1;
      lis.upZ.value = 0;
    } else {
      lis.setPosition(l.x, l.y, l.z);
      lis.setOrientation(l.fx / len, 0, l.fz / len, 0, 1, 0);
    }
    final now = ctx.currentTime;
    _hearJukebox(now);
    _scheduleTyping(now);
    _tickFridge(now);
    if (now >= _nextBird) {
      // Birds sing by day, and not in the rain.
      if (_night < 0.5 && _rain < 0.1) _birds(now);
      // Sometimes another bird answers from a different window.
      _nextBird = now + (_rng.nextDouble() < 0.35 ? _rand(1.5, 4) : _rand(12, 35));
    }
    if (now >= _nextCricket) {
      if (_night > 0.6 && _rain < 0.05) _crickets(now);
      _nextCricket = now + _rand(3, 8);
    }
    _tickRain(now);
    if (now >= _nextPhone) {
      _phone(now);
      _nextPhone = now + _rand(90, 240);
    }
    if (now >= _nextFidget) {
      _fidget(now);
      _nextFidget = now + _rand(10, 30);
    }
  }

  // ---- Workers typing ----------------------------------------------------------------------------

  /// The worker at desk (x, z) types while `on`.
  void setTyping(String id, double x, double z, bool on) {
    final t = _typists.putIfAbsent(id, () => Typist<web.PannerNode>(x, z));
    final p = t.panner;
    if (p != null && (t.x != x || t.z != z)) place(p, x, 0.9, z);
    t.x = x;
    t.z = z;
    if (on && !t.on) t.next = 0;
    t.on = on;
  }

  void removeTypist(String id) {
    _typists[id]?.panner?.disconnect();
    _typists.remove(id);
  }

  void _scheduleTyping(double now) {
    for (final t in _typists.values) {
      if (!t.on) continue;
      final p = t.panner ??= _panner(Pos(t.x, 0.9, t.z), 1.2, 1.3)..connect(_ambience);
      t.schedule(now, _rng, (when, kind) => _key(p, when, kind));
    }
  }

  void _key(web.PannerNode dest, double when, KeyKind kind) {
    final b = _buf;
    final buf = switch (kind) {
      KeyKind.key => _pick(b.keys),
      KeyKind.mouse => b.mouse,
      _ => _pick(b.spaces),
    };
    final gain = switch (kind) {
      KeyKind.enter => 0.55,
      KeyKind.space => 0.4,
      KeyKind.mouse => 0.3,
      KeyKind.key => _rand(0.24, 0.34),
    };
    _play(buf, gain: gain, rate: _rand(0.93, 1.07), when: when, dest: dest);
    _count(kind.name);
  }

  // ---- Footsteps --------------------------------------------------------------------------------

  /// One of your own footsteps, or the thump of landing a jump.
  void step([StepKind kind = StepKind.walk]) {
    if (_ctx == null) return;
    if (kind == StepKind.land) {
      _play(_pick(_buf.steps), gain: 0.5, rate: 0.75);
    } else {
      _play(_pick(_buf.steps), gain: _rand(0.16, 0.21), rate: _rand(0.9, 1.1));
    }
    _count(kind == StepKind.land ? 'land' : 'step');
  }

  /// An issue card in your hands: taken off the board, or put down on a desk.
  void paper() {
    if (_ctx == null) return;
    _play(_buf.rustle, gain: 0.5, rate: _rand(1.1, 1.3));
    _count('paper');
  }

  /// Someone else's footstep, on the office floor unless `y` says where else.
  void stepAt(double x, double z, [double y = 0]) {
    if (_ctx == null) return;
    _play(_pick(_buf.steps), at: Pos(x, y + 0.1, z), gain: _rand(0.3, 0.38), rate: _rand(0.9, 1.1), ref: 1.5, rolloff: 1.4);
    _count('peerStep');
  }

  // ---- The coffee machine -------------------------------------------------------------------------

  /// Grind, gurgle and drip.
  void coffee() {
    final ctx = _ctx;
    if (ctx == null) return;
    _count('coffee');
    final out = _panner(coffeeMachine, 1.2, 1);
    out.connect(_ambience);
    final t0 = ctx.currentTime + 0.05;

    // Grinder: a buzzing motor with beans crunching in it.
    final motor = ctx.createOscillator();
    motor.type = 'sawtooth';
    motor.frequency.setValueAtTime(70, t0);
    motor.frequency.linearRampToValueAtTime(118, t0 + 0.25);
    motor.frequency.setValueAtTime(118, t0 + 1.2);
    motor.frequency.linearRampToValueAtTime(60, t0 + 1.5);
    final motorTone = biquad(ctx, 'lowpass', 1100, 0.8);
    final crunch = _noise(_buf.white);
    final crunchTone = biquad(ctx, 'bandpass', 2600, 1.2);
    final grind = ctx.createGain();
    envelope(grind.gain, t0, const [(0.08, 0.13), (1.25, 0.13), (1.5, 0)]);
    final crunchAmp = ctx.createGain();
    crunchAmp.gain.value = 0.5;
    final rattle = _noise(_buf.gurgle, loop: true);
    rattle.playbackRate.value = 3;
    rattle.connect(crunchAmp.gain);
    motor.to(motorTone).to(grind);
    crunch.to(crunchTone).to(crunchAmp).to(grind);
    grind.connect(out);

    // Brewing: a hissing, gurgling pour with bubbles popping.
    final t1 = t0 + 1.8;
    final pour = _noise(_buf.white);
    final pourTone = biquad(ctx, 'bandpass', 850, 0.9);
    final gurgle = ctx.createGain();
    gurgle.gain.value = 0.25;
    final wobble = _noise(_buf.gurgle, loop: true);
    wobble.connect(gurgle.gain);
    final brew = ctx.createGain();
    envelope(brew.gain, t1, const [(0.2, 0.3), (2.4, 0.26), (3, 0)]);
    pour.to(pourTone).to(gurgle).to(brew).to(out);
    for (var i = 0; i < 14; i++) {
      _blip(out, t1 + _rand(0.2, 2.6), _rand(350, 800), _rand(1.6, 2.4), 0.05, 0.1);
    }

    // The last few drips into the cup.
    for (final dt in const [3.3, 3.9, 4.7]) {
      _blip(out, t1 + dt + _rand(-0.1, 0.1), _rand(1100, 1400), 0.55, 0.05, 0.11);
    }

    final end = t1 + 3.2;
    for (final web.AudioScheduledSourceNode s in [motor, crunch, rattle]) {
      s.start(t0);
      s.stop(t0 + 1.6);
    }
    for (final s in [pour, wobble]) {
      s.start(t1);
      s.stop(end);
    }
  }

  // ---- The dog ----------------------------------------------------------------------------------

  /// A few gruff woofs from where the dog is.
  @override
  void bark(double x, double z, int times) {
    final ctx = _ctx;
    if (ctx == null) return;
    _count('bark');
    final out = _panner(Pos(x, 0.5, z), 2, 1);
    out.connect(_ambience);
    var t = ctx.currentTime + 0.03;
    final pitch = _rand(0.95, 1.05);
    for (var i = 0; i < times; i++) {
      _woof(out, t, 300 * pitch * _rand(0.95, 1.05), 0.17, 0.55);
      t += _rand(0.3, 0.42);
    }
  }

  /// A short, high, happy yip: someone petted the dog.
  @override
  void yip(double x, double z) {
    final ctx = _ctx;
    if (ctx == null) return;
    _count('yip');
    final out = _panner(Pos(x, 0.5, z), 1.5, 1);
    out.connect(_ambience);
    _woof(out, ctx.currentTime + 0.02, 620, 0.09, 0.3);
  }

  /// One bark: a buzzy voice that leaps up in pitch and falls away, shaped into a "wuh", with a breathy rasp.
  void _woof(web.AudioNode out, double t, double f, double len, double gain) {
    final ctx = _ctx!;
    final voice = ctx.createOscillator();
    voice.type = 'sawtooth';
    voice.frequency.setValueAtTime(f * 0.75, t);
    voice.frequency.exponentialRampToValueAtTime(f * 1.45, t + len * 0.22);
    voice.frequency.exponentialRampToValueAtTime(f * 0.6, t + len);
    final mouth = biquad(ctx, 'bandpass', 950, 1.1);
    mouth.frequency.setValueAtTime(700, t);
    mouth.frequency.linearRampToValueAtTime(1300, t + len * 0.3);
    mouth.frequency.linearRampToValueAtTime(600, t + len);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t);
    g.gain.exponentialRampToValueAtTime(gain, t + 0.012);
    g.gain.exponentialRampToValueAtTime(gain * 0.45, t + len * 0.5);
    g.gain.exponentialRampToValueAtTime(0.0001, t + len);
    voice.to(mouth).to(g).to(out);
    final breath = _noise(_buf.white);
    final rasp = ctx.createGain();
    rasp.gain.value = 0.35;
    breath.to(biquad(ctx, 'bandpass', 1800, 0.8)).to(rasp).to(g);
    voice.start(t);
    voice.stop(t + len + 0.02);
    breath.start(t, _rand(0, 4));
    breath.stop(t + len + 0.02);
  }

  /// A short pitched blip: a bubble when `ratio` > 1, a drip when < 1.
  void _blip(web.AudioNode dest, double when, double freq, double ratio, double len, double gain) {
    final ctx = _ctx!;
    final o = ctx.createOscillator();
    o.frequency.setValueAtTime(freq, when);
    o.frequency.exponentialRampToValueAtTime(freq * ratio, when + len);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(gain, when + 0.006);
    g.gain.exponentialRampToValueAtTime(0.0001, when + len);
    o.to(g).to(dest);
    o.start(when);
    o.stop(when + len + 0.02);
  }

  /// The arcade cabinet's chip bleeps: a piece landing ('land'), lines clearing ('clear', a longer run
  /// up for more at once), the game ending ('over').
  void arcade(String kind, [int lines = 1]) {
    final ctx = _ctx;
    if (ctx == null) return;
    _count('arcade.$kind');
    final out = _panner(const Pos(lay.Cabinet.x, 1.4, lay.Cabinet.z), 1.5, 1.2);
    out.connect(_ambience);
    final t0 = ctx.currentTime + 0.02;
    if (kind == 'land') {
      _chip(out, t0, 160, 0.55, 0.07, 0.1, 'square');
    } else if (kind == 'clear') {
      const notes = [523, 659, 784, 1047, 1319];
      for (var i = 0; i < notes.length && i <= lines; i++) {
        _chip(out, t0 + i * 0.07, notes[i].toDouble(), 1.02, 0.1, 0.09, 'square');
      }
    } else {
      const notes = [392, 330, 262, 196];
      for (var i = 0; i < notes.length; i++) {
        _chip(out, t0 + i * 0.18, notes[i].toDouble(), 0.97, 0.17, 0.14, 'triangle');
      }
    }
  }

  /// The basketball: a bounce ('bounce'), the rim ringing ('rim'), the backboard ('board'), or the
  /// swish through the net ('score'), [speed] m/s hard, at [x], [y], [z].
  void ball(String kind, double x, double y, double z, double speed) {
    final ctx = _ctx;
    if (ctx == null) return;
    _count('ball-$kind');
    final loud = math.min(1.0, speed / 7);
    final out = _panner(Pos(x, y, z), 2, 1.1);
    out.connect(_ambience);
    final t0 = ctx.currentTime + 0.005;
    if (kind == 'bounce') {
      // The pong of the air inside, over a slap on the floor.
      _blip(out, t0, _rand(150, 175), 0.7, 0.16, 0.05 + 0.3 * loud);
      _play(_pick(_buf.steps), gain: 0.15 + 0.5 * loud, rate: _rand(1.25, 1.4), dest: out);
    } else if (kind == 'rim') {
      // Steel ringing, a little out of tune with itself.
      final f = _rand(520, 600);
      for (final (ratio, amp, len) in const [(1.0, 0.1, 0.5), (2.43, 0.06, 0.35), (4.1, 0.03, 0.2)]) {
        _blip(out, t0, f * ratio, 0.99, len, amp * (0.3 + loud));
      }
      _play(_pick(_buf.steps), gain: 0.2 * loud, rate: 1.9, dest: out);
    } else if (kind == 'board') {
      _play(_pick(_buf.steps), gain: 0.25 + 0.5 * loud, rate: 0.8, dest: out);
      _blip(out, t0, 240, 0.8, 0.12, 0.05 + 0.1 * loud);
    } else {
      // Swish: a breath of noise through the net, brightening as it goes.
      final n = _noise(_buf.white);
      final tone = biquad(ctx, 'bandpass', 2400, 1.2);
      tone.frequency.setValueAtTime(1800, t0);
      tone.frequency.linearRampToValueAtTime(4200, t0 + 0.28);
      final g = ctx.createGain();
      envelope(g.gain, t0, const [(0.03, 0.22), (0.18, 0.14), (0.34, 0)]);
      n.to(tone).to(g).to(out);
      n.start(t0);
      n.stop(t0 + 0.4);
    }
  }

  /// A [_blip] with its oscillator's wave shape set: a chip tune's square or triangle.
  void _chip(web.AudioNode dest, double when, double freq, double ratio, double len, double gain, String type) {
    final ctx = _ctx!;
    final o = ctx.createOscillator()..type = type;
    o.frequency.setValueAtTime(freq, when);
    o.frequency.exponentialRampToValueAtTime(freq * ratio, when + len);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, when);
    g.gain.exponentialRampToValueAtTime(gain, when + 0.006);
    g.gain.exponentialRampToValueAtTime(0.0001, when + len);
    o.to(g).to(dest);
    o.start(when);
    o.stop(when + len + 0.02);
  }

  // ---- Around the room --------------------------------------------------------------------------

  void _startRoomTone() {
    final ctx = _ctx!;
    // A low rumble of building and traffic...
    final rumble = _noise(_buf.brown, loop: true);
    final rumbleG = ctx.createGain();
    rumbleG.gain.value = 0.07;
    rumble.to(biquad(ctx, 'lowpass', 300, 0.7)).to(rumbleG).to(_ambience);
    // ...and the air vents, swelling slowly.
    final air = _noise(_buf.white, loop: true);
    final airG = ctx.createGain();
    airG.gain.value = 0.009;
    final swell = ctx.createOscillator();
    swell.frequency.value = 0.06;
    final swellDepth = ctx.createGain();
    swellDepth.gain.value = 0.004;
    swell.to(swellDepth).connect(airG.gain);
    air.to(biquad(ctx, 'bandpass', 650, 0.5)).to(airG).to(_ambience);
    rumble.start();
    air.start();
    swell.start();
  }

  void _startFridge() {
    final ctx = _ctx!;
    final hum = ctx.createOscillator();
    hum.type = 'sawtooth';
    hum.frequency.value = 50;
    final whine = ctx.createOscillator();
    whine.frequency.value = 120;
    final whineG = ctx.createGain();
    whineG.gain.value = 0.3;
    final gain = ctx.createGain();
    gain.gain.value = 0;
    final tone = biquad(ctx, 'lowpass', 220, 0.7);
    hum.connect(tone);
    whine.to(whineG).to(tone);
    final out = _panner(fridge, 1, 1.6);
    tone.to(gain).to(out).to(_ambience);
    hum.start();
    whine.start();
    _fridge = _Fridge(gain, ctx.currentTime + _rand(3, 12));
  }

  /// The compressor kicks on for a while, then clunks off.
  void _tickFridge(double now) {
    final f = _fridge;
    if (f == null || now < f.next) return;
    f.on = !f.on;
    f.gain.gain.setTargetAtTime(f.on ? 0.06 : 0, now, f.on ? 0.6 : 0.3);
    f.next = now + (f.on ? _rand(25, 50) : _rand(20, 45));
    _play(_pick(_buf.steps), at: fridge, gain: 0.25, rate: 0.6, ref: 1, rolloff: 1.6);
    _count(f.on ? 'fridgeOn' : 'fridgeOff');
  }

  /// A few chirps from outside one of the windows.
  void _birds(double now) {
    final ctx = _ctx!;
    _count('birds');
    final out = _panner(_pick(soundWindows), 2, 1.2);
    // Heard through the glass.
    out.to(biquad(ctx, 'lowpass', 5000, 0.7)).to(_ambience);
    final base = _rand(2400, 4200);
    final shape = _rng.nextDouble();
    var t = now + 0.05;
    for (var i = _randInt(2, 6); i > 0; i--) {
      final len = _rand(0.06, 0.14);
      final o = ctx.createOscillator();
      o.frequency.setValueAtTime(base * _rand(0.9, 1.05), t);
      if (shape < 0.5) {
        o.frequency.exponentialRampToValueAtTime(base * _rand(1.25, 1.6), t + len * 0.6);
        o.frequency.exponentialRampToValueAtTime(base * _rand(0.8, 1), t + len);
      } else {
        o.frequency.exponentialRampToValueAtTime(base * _rand(0.6, 0.75), t + len);
      }
      final g = ctx.createGain();
      g.gain.setValueAtTime(0.0001, t);
      g.gain.exponentialRampToValueAtTime(0.06, t + 0.012);
      g.gain.exponentialRampToValueAtTime(0.0001, t + len);
      o.to(g).to(out);
      o.start(t);
      o.stop(t + len + 0.02);
      t += len + _rand(0.04, 0.2);
    }
  }

  /// A cricket just outside a window, chirping away for a few seconds.
  void _crickets(double now) {
    final ctx = _ctx!;
    _count('crickets');
    final out = _panner(_pick(soundWindows), 2, 1.2);
    out.to(biquad(ctx, 'lowpass', 6000, 0.7)).to(_ambience);
    final freq = _rand(4200, 5200);
    var t = now + 0.05;
    for (var c = _randInt(4, 9); c > 0; c--) {
      for (var p = 0; p < 3; p++) {
        final o = ctx.createOscillator();
        o.frequency.value = freq;
        final g = ctx.createGain();
        g.gain.setValueAtTime(0.0001, t);
        g.gain.exponentialRampToValueAtTime(0.022, t + 0.004);
        g.gain.exponentialRampToValueAtTime(0.0001, t + 0.022);
        o.to(g).to(out);
        o.start(t);
        o.stop(t + 0.03);
        t += 0.035;
      }
      t += _rand(0.35, 0.6);
    }
  }

  /// Rain: a hiss that's muffled indoors, and drops pattering on the windows or all around you.
  void _tickRain(double now) {
    final rain = _rain;
    if (rain < 0.01 && _rainNodes == null) return;
    final ctx = _ctx!;
    final where = whereIs(_listener);
    var nodes = _rainNodes;
    if (nodes == null) {
      final src = _noise(_buf.white, loop: true);
      final tone = biquad(ctx, 'lowpass', 1300, 0.5);
      final gain = ctx.createGain();
      gain.gain.value = 0;
      src.to(biquad(ctx, 'highpass', 450, 0.5)).to(tone).to(gain).to(_ambience);
      src.start();
      nodes = _rainNodes = (gain: gain, tone: tone);
    }
    if (now >= _nextRain) {
      // A few updates a second; its level eases anyway.
      _nextRain = now + 0.25;
      nodes.gain.gain.setTargetAtTime(rainLevel(rain, where), now, 0.6);
      nodes.tone.frequency.setTargetAtTime(rainCutoff(where), now, 0.3);
    }
    if (rain > 0.05 && now >= _nextDrip) {
      _nextDrip = now + _rand(0.03, 0.2) / rain;
      final l = _listener;
      final at = where == Where.office ? _pick(soundWindows) : Pos(l.x + _rand(-4, 4), l.y - 1.2, l.z + _rand(-4, 4));
      _play(_buf.drop, at: at, gain: _rand(0.05, 0.14), rate: _rand(0.7, 1.4), ref: 1.5, rolloff: 1.3);
      _count('drip');
    }
  }

  /// Thunder, `delay` seconds after the flash: a crack when it's close, then a long low rumble.
  void thunder(double delay, double loud) {
    final ctx = _ctx;
    if (ctx == null || (ctx.state != 'running' && !_offline)) return;
    _count('thunder');
    final t0 = ctx.currentTime + delay;
    final peak = 0.45 * loud * (whereIs(_listener) == Where.office ? 0.6 : 1);
    final src = _noise(_buf.brown, loop: true);
    final tone = biquad(ctx, 'lowpass', 700, 0.7);
    tone.frequency.setValueAtTime(700, t0);
    tone.frequency.exponentialRampToValueAtTime(110, t0 + 3.5);
    final g = ctx.createGain();
    g.gain.setValueAtTime(0.0001, t0);
    g.gain.exponentialRampToValueAtTime(peak, t0 + 0.08 + (1 - loud) * 0.5);
    g.gain.exponentialRampToValueAtTime(peak * 0.35, t0 + 1.3);
    g.gain.exponentialRampToValueAtTime(peak * 0.6, t0 + 1.9);
    g.gain.exponentialRampToValueAtTime(0.0001, t0 + 4 + loud * 2.5);
    src.to(tone).to(g).to(_ambience);
    src.start(t0, _rand(0, 5));
    src.stop(t0 + 7);
    if (delay < 1) {
      final crack = _noise(_buf.white);
      final cg = ctx.createGain();
      envelope(cg.gain, t0, [(0.01, peak * 0.5), (0.25, 0)]);
      crack.to(biquad(ctx, 'bandpass', 1800, 0.6)).to(cg).to(_ambience);
      crack.start(t0);
      crack.stop(t0 + 0.3);
    }
  }

  /// A desk phone rings a couple of times somewhere across the room, then someone picks up.
  void _phone(double now) {
    final ctx = _ctx!;
    final l = _listener;
    final far = [
      for (final d in desks)
        if (math.sqrt((d.x - l.x) * (d.x - l.x) + (d.z - l.z) * (d.z - l.z)) > 7) d,
    ];
    final desk = _pick(far.isNotEmpty ? far : desks);
    _count('phone');
    final out = _panner(Pos(desk.x, 0.9, desk.z), 1.5, 1.2);
    out.to(biquad(ctx, 'lowpass', 3000, 0.7)).to(_ambience);
    final rings = _randInt(2, 3);
    for (var r = 0; r < rings; r++) {
      final t = now + 0.05 + r * 2.4;
      final o = ctx.createOscillator();
      o.type = 'triangle';
      // A warbling trill, flipping between two notes.
      for (var k = 0; k < 18; k++) {
        o.frequency.setValueAtTime(k.isOdd ? 1450 : 1150, t + k / 18);
      }
      final g = ctx.createGain();
      envelope(g.gain, t, const [(0.02, 0.045), (0.95, 0.045), (1, 0)]);
      o.to(g).to(out);
      o.start(t);
      o.stop(t + 1.05);
    }
  }

  /// Someone at a worker's desk shuffles papers or leans back in a creaky chair.
  void _fidget(double now) {
    final desks = _typists.values.toList();
    if (desks.isEmpty) return;
    final d = _pick(desks);
    if (_rng.nextDouble() < 0.6) {
      _play(_buf.rustle, at: Pos(d.x, 0.8, d.z), gain: 0.35, rate: _rand(0.85, 1.15), ref: 1.2, rolloff: 1.3);
      _count('rustle');
      return;
    }
    final ctx = _ctx!;
    final out = _panner(Pos(d.x, 0.5, d.z), 1.2, 1.3);
    out.connect(_ambience);
    final len = _rand(0.25, 0.45);
    final o = ctx.createOscillator();
    o.type = 'sawtooth';
    final f = _rand(150, 200);
    o.frequency.setValueAtTime(f, now);
    o.frequency.linearRampToValueAtTime(f * _rand(1.2, 1.5), now + len);
    final g = ctx.createGain();
    envelope(g.gain, now, [(0.05, 0.05), (len - 0.05, 0.04), (len, 0)]);
    o.to(biquad(ctx, 'bandpass', _rand(900, 1300), 7)).to(g).to(out);
    o.start(now);
    o.stop(now + len + 0.02);
    _count('creak');
  }

  // ---- The gong ----------------------------------------------------------------------------------

  /// The gong by the PR board rings: someone hit it, a pull request merged (a harder stroke), or the
  /// task queue emptied (three strokes, each bigger than the last). From where it hangs, so you hear
  /// which way it is.
  void gong(GongWhy why) {
    unlock();
    final ctx = _ctx;
    if (ctx == null) return;
    if (ctx.state == 'suspended' && !_offline) quietly((ctx as web.AudioContext).resume());
    _count('gong.${why.wire}');
    // Someone banging it is the room; a merge is news for the whole floor (and from another tab too,
    // like the dings), so it carries further.
    final out = why == GongWhy.hit ? _panner(gongAt, 4, 0.6) : _panner(gongAt, 8, 0.45);
    out.connect(why == GongWhy.hit ? _ambience : _alerts);
    final t0 = ctx.currentTime + 0.03;
    if (why == GongWhy.queue) {
      const strengths = [0.7, 0.85, 1.1];
      for (var i = 0; i < strengths.length; i++) {
        _strike(out, t0 + i * 0.85, strengths[i]);
      }
    } else {
      _strike(out, t0, why == GongWhy.merged ? 1 : _rand(0.6, 0.8));
    }
  }

  /// One stroke of the mallet: a felt thump, the metal ringing, and a bright wash that blooms after.
  void _strike(web.AudioNode out, double t0, double strength) {
    final ctx = _ctx!;
    final f0 = 118 * _rand(0.98, 1.02);
    final ring = ctx.createGain();
    ring.gain.value = 0.3 * strength;
    ring.connect(out);
    final long = 0.6 + 0.4 * strength;
    for (final (ratio, amp, decay) in gongPartials) {
      final f = f0 * ratio;
      final end = t0 + decay * long;
      // Two of each a few cents apart, so the tone shimmers as it rings.
      for (final cents in const [-1, 1]) {
        final o = ctx.createOscillator();
        // Struck hard, a gong starts a touch sharp and settles.
        o.frequency.setValueAtTime(f * (1 + 0.012 * strength), t0);
        o.frequency.exponentialRampToValueAtTime(f, t0 + 1.2);
        o.detune.value = cents * _rand(2, 5);
        final g = ctx.createGain();
        g.gain.setValueAtTime(0.0001, t0);
        g.gain.exponentialRampToValueAtTime(amp * 0.5, t0 + 0.01 + ratio * 0.004);
        g.gain.exponentialRampToValueAtTime(0.0001, end);
        o.to(g).to(ring);
        o.start(t0);
        o.stop(end + 0.05);
      }
    }
    final thump = _noise(_buf.white);
    final thumpG = ctx.createGain();
    thumpG.gain.setValueAtTime(0.0001, t0);
    thumpG.gain.exponentialRampToValueAtTime(0.45 * strength, t0 + 0.005);
    thumpG.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.12);
    thump.to(biquad(ctx, 'lowpass', 420, 0.8)).to(thumpG).to(out);
    thump.start(t0);
    thump.stop(t0 + 0.15);
    final wash = _noise(_buf.white, loop: true);
    final washG = ctx.createGain();
    washG.gain.setValueAtTime(0, t0);
    washG.gain.linearRampToValueAtTime(0.03 * strength, t0 + 0.45);
    washG.gain.exponentialRampToValueAtTime(0.0001, t0 + 3.5 * long);
    wash.to(biquad(ctx, 'bandpass', 3200, 1.2)).to(washG).to(out);
    wash.start(t0);
    wash.stop(t0 + 3.5 * long + 0.05);
  }

  // ---- Alerts ----------------------------------------------------------------------------------

  /// Two notes up when a worker is done, a three-note nudge when it needs input.
  void ding(Ding kind) {
    unlock();
    final ctx = _ctx;
    if (ctx == null) return;
    if (ctx.state == 'suspended' && !_offline) quietly((ctx as web.AudioContext).resume());
    _count(kind == Ding.done ? 'done' : 'needs_input');
    final notes = kind == Ding.done ? const [660.0, 880.0] : const [880.0, 660.0, 880.0];
    for (var i = 0; i < notes.length; i++) {
      final o = ctx.createOscillator();
      final g = ctx.createGain();
      o.type = 'triangle';
      o.frequency.value = notes[i];
      final t0 = ctx.currentTime + i * 0.12;
      g.gain.setValueAtTime(0.0001, t0);
      g.gain.exponentialRampToValueAtTime(0.3, t0 + 0.02);
      g.gain.exponentialRampToValueAtTime(0.0001, t0 + 0.25);
      o.to(g).to(_alerts);
      o.start(t0);
      o.stop(t0 + 0.3);
    }
  }

  // ---- The jukebox ------------------------------------------------------------------------------

  /// What the jukebox on your floor plays, or null for nothing. It starts once the browser allows audio.
  void setJukebox(JukeboxPlay? play) {
    final was = _jukebox;
    _jukebox = play;
    // The same play, sent again after a reconnect or timed better once the clocks are compared: carry on
    // (a tune lines itself up again as it goes; an audio file jumps to the right spot).
    if (was != null && play != null && was.samePlayAs(play)) {
      final s = _stream;
      if (s != null && (was.since - play.since).abs() > 250) _seekStream(s);
      return;
    }
    _applyJukebox(changed: true);
  }

  /// Your own jukebox volume, 0–1, apart from the office sounds'.
  void setMusicVolume(double volume, bool muted) {
    _musicVolume = volume.clamp(0, 1).toDouble();
    _musicMuted = muted;
    _applyMusicVolume();
  }

  /// 1 on each beat of the tune, falling to 0 before the next, for the jukebox's lights.
  double beat() {
    final tune = _tune;
    if (tune != null) return tune.beat(_musicAt());
    final s = _stream;
    if (s != null && !s.paused) return 0.35 + 0.25 * math.sin(_now() / 320);
    return 0;
  }

  /// The tune playing now, if any (for checks).
  TunePlayer? get tune => _tune;

  /// How far into the jukebox's track it is now, in seconds.
  double _musicAt() {
    final j = _jukebox;
    return j == null ? 0 : math.max(0, (_now() - j.since) / 1000);
  }

  void _applyMusicVolume() {
    final ctx = _ctx;
    if (ctx == null) return;
    _musicBus.gain.setTargetAtTime(_musicGain(), ctx.currentTime, 0.04);
    _hearStream();
  }

  double _musicGain() => _musicMuted ? 0 : _musicVolume * _musicVolume;

  /// Starts what the jukebox plays now, once there's audio; `changed` puts it on again from the top.
  void _applyJukebox({bool changed = false}) {
    final ctx = _ctx;
    if (ctx == null || (!changed && (_tune != null || _stream != null))) return;
    _tune?.stop();
    _tune = null;
    final s = _stream;
    if (s != null) {
      s.pause();
      s.removeAttribute('src');
      s.load();
      _stream = null;
    }
    _musicTimer?.cancel();
    _musicTimer = null;
    final j = _jukebox;
    if (j == null) return;
    final url = j.url;
    if (j.track == jukeboxStream && url != null && url.isNotEmpty) return _startStream(url);
    final tune = _tune = TunePlayer(ctx, _musicIn, j.track);
    _count('tune');
    // On a timer rather than every frame, so it carries on in a background tab.
    void tick() => tune.tick(_musicAt());
    tick();
    _musicTimer = Timer.periodic(const Duration(milliseconds: 150), (_) => tick());
  }

  void _startStream(String url) {
    final a = web.HTMLAudioElement();
    a.preload = 'auto';
    a.loop = true;
    a.src = url;
    a.addEventListener('loadedmetadata', ((web.Event _) => _seekStream(a)).toJS);
    a.addEventListener(
      'error',
      ((web.Event _) {
        if (identical(_stream, a)) onMusicError?.call("📻 The jukebox can't play that stream in your browser");
      }).toJS,
    );
    _stream = a;
    _hearStream();
    quietly(a.play());
    _count('stream');
  }

  /// An audio file (not live radio) picks up where everyone else is.
  void _seekStream(web.HTMLAudioElement a) {
    final d = a.duration;
    if (d.isFinite && d > 0) a.currentTime = _musicAt() % d;
  }

  /// Muffles the jukebox the further you are from it.
  void _hearJukebox(double now) {
    final cutoff = musicCutoffAt(jukeboxDistance(_listener));
    if ((cutoff - _musicCutoff).abs() > _musicCutoff * 0.02) {
      _musicCutoff = cutoff;
      _musicTone.frequency.setTargetAtTime(cutoff, now, 0.1);
    }
    _hearStream();
  }

  /// A stream plays outside Web Audio (most don't allow that), so it gets quieter with distance by hand.
  void _hearStream() {
    final s = _stream;
    if (s == null) return;
    s.volume = streamVolume(_musicGain(), jukeboxDistance(_listener));
  }

  // ---- Plumbing --------------------------------------------------------------------------------

  web.PannerNode _panner(Pos p, [double ref = 1.5, double rolloff = 1.2]) {
    final pn = _ctx!.createPanner();
    pn.panningModel = 'equalpower';
    pn.distanceModel = 'inverse';
    pn.refDistance = ref;
    pn.rolloffFactor = rolloff;
    place(pn, p.x, p.y, p.z);
    return pn;
  }

  web.AudioBufferSourceNode _noise(web.AudioBuffer buffer, {bool loop = false}) {
    final s = _ctx!.createBufferSource();
    s.buffer = buffer;
    s.loop = loop;
    return s;
  }

  void _play(web.AudioBuffer buffer, {Pos? at, double? when, double gain = 1, double rate = 1, web.AudioNode? dest, double ref = 1.5, double rolloff = 1.2}) {
    final ctx = _ctx!;
    final src = ctx.createBufferSource();
    src.buffer = buffer;
    src.playbackRate.value = rate;
    final g = ctx.createGain();
    g.gain.value = gain;
    src.connect(g);
    web.AudioNode out = g;
    if (at != null) out = g.to(_panner(at, ref, rolloff));
    out.connect(dest ?? _ambience);
    src.start(when ?? ctx.currentTime);
  }
}

class _Fridge {
  _Fridge(this.gain, this.next);

  final web.GainNode gain;
  bool on = false;
  double next;
}

/// The samples as AudioBuffers, made once when audio starts.
class _Buffers {
  factory _Buffers(web.BaseAudioContext ctx) {
    final s = OfficeSamples(ctx.sampleRate.round(), _rng);
    web.AudioBuffer b(Float32List d) => audioBuffer(ctx, [d]);
    return _Buffers._(
      keys: s.keys.map(b).toList(),
      spaces: s.spaces.map(b).toList(),
      mouse: b(s.mouse),
      steps: s.steps.map(b).toList(),
      rustle: b(s.rustle),
      drop: b(s.drop),
      brown: b(s.brown),
      white: b(s.white),
      gurgle: b(s.gurgle),
    );
  }

  _Buffers._({
    required this.keys,
    required this.spaces,
    required this.mouse,
    required this.steps,
    required this.rustle,
    required this.drop,
    required this.brown,
    required this.white,
    required this.gurgle,
  });

  final List<web.AudioBuffer> keys;
  final List<web.AudioBuffer> spaces;
  final web.AudioBuffer mouse;
  final List<web.AudioBuffer> steps;
  final web.AudioBuffer rustle;

  /// A raindrop hitting the glass.
  final web.AudioBuffer drop;
  final web.AudioBuffer brown;
  final web.AudioBuffer white;

  /// A slow, lumpy 0–1 signal for wobbling other sounds' volume.
  final web.AudioBuffer gurgle;
}
