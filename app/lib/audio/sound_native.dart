// The office's sound in the desktop app: the same sounds as the web's Web Audio graphs (sound_web.dart),
// rendered to PCM by the offline synth (office_render.dart, music_render.dart) and played through SoLoud
// (audio_engine.dart). The one-shots and the room's loops are rendered once, in the background, when
// the app starts: the gong and the dings first. Where a sound comes from is a Web Audio panner's
// sums (sound_model.dart's hearAt), redone every frame as you move.
//
// The levels follow the web's: one master volume (squared, and the makeup gain of the web's master
// compressor) for the office, the room's ambience fading out while the window's hidden (the alerts
// and the music don't), the office's hum giving way to the wind up on the roof, and the music with a
// volume of its own.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/widgets.dart' show AppLifecycleState, WidgetsBinding;

import 'package:office_shared/layout.dart' show DjBooth, desks;
import 'package:office_shared/layout.dart' as lay show Cabinet;
import 'package:office_shared/protocol.dart' show GongWhy;

import '../state/store.dart' show nowMs;
import 'audio_engine.dart';
import 'music_stream.dart';
import 'office_render.dart';
import 'sound_model.dart';
import 'synth.dart';

export 'sound_model.dart' show Ding, DogSounds, JukeboxPlay, SoundListener, StepKind;

final math.Random _rng = math.Random();
double _rand(double a, double b) => a + _rng.nextDouble() * (b - a);
int _randInt(int a, int b) => _rand(a.toDouble(), b + 1.0).floor();
T _pick<T>(List<T> xs) => xs[(_rng.nextDouble() * xs.length).floor()];

/// The web's master compressor (sound_web.dart) adds this much back after compressing: quiet sounds
/// come out this much louder than they went in.
final double officeMakeup = Compressor(
  threshold: -14,
  knee: 12,
  ratio: 4,
  attack: 0.004,
  release: 0.25,
  sr: nativeSampleRate,
).makeup;

// In a background isolate. Top-level, so the closures capture nothing but their arguments.
Future<Map<String, Float32List>> _renderBank(int sr, Bank bank) => Isolate.run(() => renderBank(sr, bank));
Future<Float32List> _renderThunder(int sr, double loud, double peak, bool crack) =>
    Isolate.run(() => OfficeRender(sr).thunder(loud, peak, crack));

enum _Bus { ambience, alerts, indoors, outside, music }

/// Something playing: where it is, and how loud before the room and the volume.
class _Voice {
  _Voice(this.id, this.bus, this.gain, this.until, {this.at, this.ref = 1.5, this.rolloff = 1.2});

  final int id;
  final _Bus bus;
  double gain;

  /// When it's over, on the sound's own clock (infinity for a loop).
  final double until;
  Pos? at;
  final double ref;
  final double rolloff;
  bool paused = false;
  double _vol = -1, _l = -1, _r = -1;
}

class _Typist {
  _Typist(this.x, this.z);

  double x;
  double z;
  bool on = false;
  _Voice? voice;
}

class OfficeSound implements DogSounds {
  /// Starts the engine straight away (a desktop app needs no click first). [engine] stands in for
  /// SoLoud (in tests); with none under `flutter test`, it stays silent.
  OfficeSound({double Function()? clock, AudioEngine? engine})
    : _now = clock ?? nowMs,
      _engine = engine ?? _defaultEngine() {
    _start();
  }

  static AudioEngine? _defaultEngine() => Platform.environment.containsKey('FLUTTER_TEST') ? null : SoLoudEngine();

  /// How many OfficeSounds are using the engine, so the last one out shuts it down.
  static int _users = 0;

  final double Function() _now;
  final AudioEngine? _engine;
  final Stopwatch _clock = Stopwatch()..start();
  double get _t => _clock.elapsedMicroseconds / 1e6;

  String _state = 'locked';
  bool _disposed = false;
  bool get _ready => _state == 'running';

  /// Sources by name; a name with variants has several.
  final Map<String, List<int>> _bank = {};
  final Map<int, double> _lengths = {};
  final List<_Voice> _voices = [];
  Timer? _ticker;
  double _lastTick = 0;

  // Levels, eased towards their targets like the web's setTargetAtTime.
  double _volume = 0.7;
  bool _muted = false;
  double _master = 0;
  double _ambience = 1;
  double _indoors = 1;
  double _outside = 0;
  bool _outdoors = false;

  // The room.
  _Voice? _fridgeHum;
  bool _fridgeOn = false;
  double _fridgeLevel = 0;
  double _nextFridge = 0;
  final Map<String, _Voice> _rainVoices = {};
  final Map<String, double> _rainMix = {'office': 0, 'garage': 0, 'out': 0};
  double _rainLevel = 0;
  double _nextDrip = 0;
  double _nextBird = 0;
  double _nextCricket = 0;
  double _nextPhone = 0;
  double _nextFidget = 0;
  double _rain = 0;
  double _night = 0;
  SoundListener _listener = const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1);
  final Map<String, _Typist> _typists = {};

  // The music.
  late final MusicStreams _music = MusicStreams(_engine, _now)..onError = (text) => onMusicError?.call(text);

  /// A stream that won't play here.
  void Function(String text)? onMusicError;

  /// How many of each sound have played, for quick checks.
  final Map<String, int> played = {};

  void _count(String what) => played[what] = (played[what] ?? 0) + 1;

  // ---- Starting and stopping -------------------------------------------------------------------

  void _start() {
    final e = _engine;
    if (e == null) {
      _state = 'unavailable';
      return;
    }
    _state = 'starting';
    _users++;
    unawaited(_boot(e));
  }

  Future<void> _boot(AudioEngine e) async {
    try {
      await e.init(nativeSampleRate);
    } catch (err) {
      debugPrint('sound: no audio ($err)');
      _state = 'unavailable';
      return;
    }
    if (_disposed) return;
    _state = 'running';
    _music.ready = true;
    _ticker = Timer.periodic(const Duration(milliseconds: 50), (_) => _tick());
    final now = _t;
    _nextBird = now + _rand(5, 15);
    _nextCricket = now + _rand(2, 6);
    _nextPhone = now + _rand(60, 150);
    _nextFidget = now + _rand(8, 20);
    _nextFridge = now + _rand(3, 12);
    _music.apply();
    // The gong and the dings first, then the room, then everything else.
    for (final bank in Bank.values) {
      const sr = nativeSampleRate;
      final Map<String, Float32List> pcm;
      try {
        pcm = await _renderBank(sr, bank);
      } catch (err) {
        debugPrint('sound: rendering $bank failed ($err)');
        continue;
      }
      for (final MapEntry(:key, :value) in pcm.entries) {
        if (_disposed) return;
        try {
          final id = await e.load([value], sr, key);
          _lengths[id] = value.length / sr;
          final dot = key.lastIndexOf('.');
          final base = dot > 0 && int.tryParse(key.substring(dot + 1)) != null ? key.substring(0, dot) : key;
          (_bank[base] ??= []).add(id);
        } catch (err) {
          debugPrint('sound: loading $key failed ($err)');
        }
      }
      if (bank == Bank.room) _startRoom();
    }
  }

  /// Stops everything this started; the last one out shuts the engine down.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _ticker?.cancel();
    _music.dispose();
    final e = _engine;
    if (e == null || _state == 'unavailable') return;
    for (final v in _voices) {
      e.stop(v.id);
    }
    _voices.clear();
    for (final ids in _bank.values) {
      for (final id in ids) {
        e.free(id);
      }
    }
    _bank.clear();
    if (--_users <= 0 && _state == 'running') e.shutdown();
    _state = 'closed';
  }

  /// Volume is 0–1; muted silences everything without losing the level.
  void setVolume(double volume, bool muted) {
    _volume = volume.clamp(0, 1).toDouble();
    _muted = muted;
  }

  /// The weather outside (see world/sky), every frame.
  void setWeather(double rain, double night) {
    _rain = rain;
    _night = night;
  }

  /// No meter on the office's output here.
  double level() => 0;

  /// The music's level where you stand, after your music volume.
  double musicLevel() => _music.level();

  /// 'running' once the engine's going ('starting' before, 'unavailable' with no audio).
  String get state => _state;

  /// The engine starts by itself; this is for the web's sake.
  void unlock() {}

  // ---- Every frame ------------------------------------------------------------------------------

  /// Moves your ears and schedules whatever the room does next.
  void update(SoundListener l) {
    _listener = l;
    _music.listener = l;
    if (!_ready) return;
    final now = _t;
    _scheduleTyping();
    if (now >= _nextBird) {
      if (_night < 0.5 && _rain < 0.1) _birds();
      _nextBird = now + (_rng.nextDouble() < 0.35 ? _rand(1.5, 4) : _rand(12, 35));
    }
    if (now >= _nextCricket) {
      if (_night > 0.6 && _rain < 0.05) _crickets();
      _nextCricket = now + _rand(3, 8);
    }
    _tickRain(now);
    if (now >= _nextPhone) {
      if (!_outdoors) _phone();
      _nextPhone = now + _rand(90, 240);
    }
    if (now >= _nextFidget) {
      if (!_outdoors) _fidget();
      _nextFidget = now + _rand(10, 30);
    }
    _tickFridge(now);
    _tick();
  }

  bool get _hidden {
    try {
      final s = WidgetsBinding.instance.lifecycleState;
      return s == AppLifecycleState.hidden || s == AppLifecycleState.paused;
    } catch (_) {
      return false;
    }
  }

  /// Eases the levels and moves every voice: from update(), and on a timer for when frames stop.
  void _tick() {
    final e = _engine;
    if (e == null || !_ready) return;
    final now = _t;
    final dt = math.max(0.0, now - _lastTick);
    _lastTick = now;
    if (dt == 0) return;
    double ease(double v, double to, double tc) => to + (v - to) * math.exp(-dt / tc);
    _master = ease(_master, _muted ? 0 : _volume * _volume, 0.04);
    _ambience = ease(_ambience, _hidden ? 0 : 1, 0.15);
    _indoors = ease(_indoors, _outdoors ? 0 : 1, 0.3);
    _outside = ease(_outside, _outdoors ? 1 : 0, 0.3);
    _fridgeLevel = ease(_fridgeLevel, _fridgeOn ? 0.06 : 0, _fridgeOn ? 0.6 : 0.3);
    _fridgeHum?.gain = _fridgeLevel;
    _easeRain(dt);
    // On the timer too, so the music keeps going while the window's hidden (no frames then).
    _music.update();
    _music.tick(dt);
    final l = _listener;
    _voices.removeWhere((v) {
      if (now > v.until) return true;
      final bus = switch (v.bus) {
        _Bus.alerts => 1.0,
        _Bus.ambience => _ambience,
        _Bus.indoors => _ambience * _indoors,
        _Bus.outside => _ambience * _outside,
        _Bus.music => 1.0,
      };
      var vol = v.gain * bus * _master * officeMakeup;
      var left = 1.0, right = 1.0;
      final at = v.at;
      if (at != null) {
        final h = hearAt(l, at, v.ref, v.rolloff);
        vol *= h.gain;
        left = h.left;
        right = h.right;
      }
      if ((vol - v._vol).abs() > 1e-4 + v._vol * 0.01) {
        v._vol = vol;
        e.setVolume(v.id, vol);
      }
      if ((left - v._l).abs() > 0.005 || (right - v._r).abs() > 0.005) {
        v._l = left;
        v._r = right;
        e.setPan(v.id, left, right);
      }
      return false;
    });
  }

  // ---- Playing ----------------------------------------------------------------------------------

  /// Plays (a variant of) [name] now: [gain] before the room and the volume, at [speed], from [at]
  /// (a panner with [ref] and [rolloff]) or from nowhere in particular. Returns the voice, or null.
  _Voice? _play(
    String name, {
    int? source,
    double gain = 1,
    double speed = 1,
    Pos? at,
    double ref = 1.5,
    double rolloff = 1.2,
    _Bus bus = _Bus.ambience,
    bool loop = false,
    double seek = 0,
    bool paused = false,
  }) {
    final e = _engine;
    final ids = source == null ? _bank[name] : [source];
    if (e == null || !_ready || ids == null || ids.isEmpty) return null;
    final src = _pick(ids);
    final len = (_lengths[src] ?? 1) / speed;
    final v = _Voice(-1, bus, gain, loop ? double.infinity : _t + len + 0.1, at: at, ref: ref, rolloff: rolloff);
    // Work out its level and pan before it starts, so it doesn't start somewhere else.
    final vol = _levelOf(v);
    final id = e.play(
      src,
      volume: vol.$1,
      left: vol.$2,
      right: vol.$3,
      speed: speed,
      loop: loop,
      seek: seek,
      paused: paused,
    );
    if (id < 0) return null;
    final voice = _Voice(id, bus, gain, v.until, at: at, ref: ref, rolloff: rolloff)
      .._vol = vol.$1
      .._l = vol.$2
      .._r = vol.$3
      ..paused = paused;
    _voices.add(voice);
    return voice;
  }

  (double, double, double) _levelOf(_Voice v) {
    final bus = switch (v.bus) {
      _Bus.alerts || _Bus.music => 1.0,
      _Bus.ambience => _ambience,
      _Bus.indoors => _ambience * _indoors,
      _Bus.outside => _ambience * _outside,
    };
    var vol = v.gain * bus * _master * officeMakeup;
    final at = v.at;
    if (at == null) return (vol, 1, 1);
    final h = hearAt(_listener, at, v.ref, v.rolloff);
    vol *= h.gain;
    return (vol, h.left, h.right);
  }

  // ---- Workers typing ---------------------------------------------------------------------------

  /// The worker at desk (x, z) types while `on`.
  void setTyping(String id, double x, double z, bool on) {
    final t = _typists.putIfAbsent(id, () => _Typist(x, z));
    t.x = x;
    t.z = z;
    t.voice?.at = Pos(x, 0.9, z);
    t.on = on;
    _applyTypist(t);
  }

  void removeTypist(String id) {
    final t = _typists.remove(id);
    final v = t?.voice;
    if (v != null) {
      _engine?.stop(v.id);
      _voices.remove(v);
    }
  }

  void _scheduleTyping() {
    for (final t in _typists.values) {
      _applyTypist(t);
    }
  }

  /// A typist's loop plays while they type, and pauses (where it got to) while they don't.
  void _applyTypist(_Typist t) {
    final e = _engine;
    if (e == null || !_ready) return;
    var v = t.voice;
    if (v == null) {
      if (!t.on) return;
      final ids = _bank['typing'];
      if (ids == null) return;
      v = t.voice = _play('typing', at: Pos(t.x, 0.9, t.z), ref: 1.2, rolloff: 1.3, loop: true, seek: _rand(0, 40));
      if (v == null) return;
      _count('typing');
    }
    if (v.paused == t.on) {
      v.paused = !t.on;
      e.setPaused(v.id, v.paused);
    }
  }

  // ---- Footsteps and the like -------------------------------------------------------------------

  /// One of your own footsteps, or the thump of landing a jump.
  void step([StepKind kind = StepKind.walk]) {
    if (!_ready) return;
    if (kind == StepKind.land) {
      _play('step', gain: 0.5, speed: 0.75);
    } else {
      _play('step', gain: _rand(0.16, 0.21), speed: _rand(0.9, 1.1));
    }
    _count(kind == StepKind.land ? 'land' : 'step');
  }

  /// An issue card in your hands: taken off the board, or put down on a desk.
  void paper() {
    if (!_ready) return;
    _play('rustle', gain: 0.5, speed: _rand(1.1, 1.3));
    _count('paper');
  }

  /// Someone else's footstep, on the office floor unless `y` says where else.
  void stepAt(double x, double z, [double y = 0]) {
    if (!_ready) return;
    _play('step', at: Pos(x, y + 0.1, z), gain: _rand(0.3, 0.38), speed: _rand(0.9, 1.1), ref: 1.5, rolloff: 1.4);
    _count('peerStep');
  }

  /// Grind, gurgle and drip.
  void coffee() {
    if (!_ready) return;
    _count('coffee');
    _play('coffee', at: coffeeMachine, ref: 1.2, rolloff: 1);
  }

  /// A few gruff woofs from where the dog is.
  @override
  void bark(double x, double z, int times) {
    if (!_ready) return;
    _count('bark');
    _play(times <= 2 ? 'bark2' : 'bark3', at: Pos(x, 0.5, z), ref: 2, rolloff: 1);
  }

  /// A short, high, happy yip: someone petted the dog.
  @override
  void yip(double x, double z) {
    if (!_ready) return;
    _count('yip');
    _play('yip', at: Pos(x, 0.5, z), ref: 1.5, rolloff: 1);
  }

  /// The arcade cabinet's chip bleeps.
  void arcade(String kind, [int lines = 1]) {
    if (!_ready) return;
    _count('arcade.$kind');
    final name = switch (kind) {
      'land' => 'arcade.land',
      'clear' => 'arcade.clear${lines.clamp(0, 4)}',
      _ => 'arcade.over',
    };
    _play(name, at: const Pos(lay.Cabinet.x, 1.4, lay.Cabinet.z), ref: 1.5, rolloff: 1.2);
  }

  /// The basketball: a bounce, the rim, the backboard, or the swish, [speed] m/s hard.
  void ball(String kind, double x, double y, double z, double speed) {
    if (!_ready) return;
    _count('ball-$kind');
    final loud = math.min(1.0, speed / 7);
    var best = 0;
    for (var i = 1; i < ballLevels.length; i++) {
      if ((ballLevels[i] - loud).abs() < (ballLevels[best] - loud).abs()) best = i;
    }
    final k = kind == 'bounce' || kind == 'rim' || kind == 'board' ? kind : 'score';
    _play('ball.$k.$best', at: Pos(x, y, z), ref: 2, rolloff: 1.1);
  }

  // ---- Around the room --------------------------------------------------------------------------

  /// The room tone, the fridge, the roof and the rain: loops, from when they're rendered.
  void _startRoom() {
    _play('room', bus: _Bus.indoors, loop: true, seek: _rand(0, 10));
    _play('roof', bus: _Bus.outside, loop: true, seek: _rand(0, 10));
    _fridgeHum = _play('fridge', gain: 0, at: fridge, ref: 1, rolloff: 1.6, bus: _Bus.indoors, loop: true);
  }

  /// The compressor kicks on for a while, then clunks off.
  void _tickFridge(double now) {
    if (now < _nextFridge || _fridgeHum == null) return;
    _fridgeOn = !_fridgeOn;
    _nextFridge = now + (_fridgeOn ? _rand(25, 50) : _rand(20, 45));
    _play('step', at: fridge, gain: 0.25, speed: 0.6, ref: 1, rolloff: 1.6, bus: _Bus.indoors);
    _count(_fridgeOn ? 'fridgeOn' : 'fridgeOff');
  }

  void _birds() {
    _count('birds');
    _play('birds', at: _pick(soundWindows), ref: 2, rolloff: 1.2);
  }

  void _crickets() {
    _count('crickets');
    _play('crickets', at: _pick(soundWindows), ref: 2, rolloff: 1.2);
  }

  /// Rain: a hiss that's muffled indoors, and drops pattering on the windows or all around you.
  void _tickRain(double now) {
    if (_rain < 0.01 && _rainLevel < 1e-4) return;
    final where = whereIs(_listener);
    for (final name in const ['office', 'garage', 'out']) {
      if (_rainVoices[name] == null && _bank['rain.$name'] != null) {
        final v = _play('rain.$name', gain: 0, loop: true, seek: _rand(0, 3));
        if (v != null) _rainVoices[name] = v;
      }
    }
    _rainTarget = rainLevel(_rain, where);
    _rainWhere = where;
    if (_rain > 0.05 && now >= _nextDrip) {
      _nextDrip = now + _rand(0.03, 0.2) / _rain;
      final l = _listener;
      final at = where == Where.office ? _pick(soundWindows) : Pos(l.x + _rand(-4, 4), l.y - 1.2, l.z + _rand(-4, 4));
      _play('drop', at: at, gain: _rand(0.05, 0.14), speed: _rand(0.7, 1.4), ref: 1.5, rolloff: 1.3);
      _count('drip');
    }
  }

  double _rainTarget = 0;
  Where _rainWhere = Where.office;

  /// The hiss eases to its level (0.6 s) and its brightness (0.3 s), like the web's.
  void _easeRain(double dt) {
    if (_rainVoices.isEmpty) return;
    _rainLevel = _rainTarget + (_rainLevel - _rainTarget) * math.exp(-dt / 0.6);
    for (final name in const ['office', 'garage', 'out']) {
      final to = _rainWhere.name == name ? 1.0 : 0.0;
      final mix = _rainMix[name] = to + (_rainMix[name]! - to) * math.exp(-dt / 0.3);
      final v = _rainVoices[name];
      if (v == null) continue;
      v.gain = _rainLevel * mix;
      final quiet = v.gain < 1e-5;
      if (quiet != v.paused) {
        v.paused = quiet;
        _engine?.setPaused(v.id, quiet);
      }
    }
  }

  /// Thunder, `delay` seconds after the flash: a crack when it's close, then a long low rumble.
  void thunder(double delay, double loud) {
    final e = _engine;
    if (e == null || !_ready) return;
    _count('thunder');
    final peak = 0.45 * loud * (whereIs(_listener) == Where.office ? 0.6 : 1);
    final crack = delay < 1;
    final asked = _t;
    unawaited(() async {
      const sr = nativeSampleRate;
      final pcm = await _renderThunder(sr, loud, peak, crack);
      if (_disposed) return;
      final id = await e.load([pcm], sr, 'thunder');
      _lengths[id] = pcm.length / sr;
      final wait = delay - (_t - asked);
      if (wait > 0) await Future<void>.delayed(Duration(microseconds: (wait * 1e6).round()));
      if (_disposed) return;
      _play('thunder', source: id);
      // Let it go once it's rumbled away.
      Timer(const Duration(seconds: 9), () => e.free(id));
    }());
  }

  /// A desk phone rings a couple of times somewhere across the room, then someone picks up.
  void _phone() {
    final l = _listener;
    final far = [
      for (final d in desks)
        if (math.sqrt((d.x - l.x) * (d.x - l.x) + (d.z - l.z) * (d.z - l.z)) > 7) d,
    ];
    final desk = _pick(far.isNotEmpty ? far : desks);
    _count('phone');
    _play('phone.${_randInt(2, 3)}', at: Pos(desk.x, 0.9, desk.z), ref: 1.5, rolloff: 1.2);
  }

  /// Someone at a worker's desk shuffles papers or leans back in a creaky chair.
  void _fidget() {
    final typists = _typists.values.toList();
    if (typists.isEmpty) return;
    final d = _pick(typists);
    if (_rng.nextDouble() < 0.6) {
      _play('rustle', at: Pos(d.x, 0.8, d.z), gain: 0.35, speed: _rand(0.85, 1.15), ref: 1.2, rolloff: 1.3);
      _count('rustle');
      return;
    }
    _play('creak', at: Pos(d.x, 0.5, d.z), ref: 1.2, rolloff: 1.3);
    _count('creak');
  }

  // ---- The gong ----------------------------------------------------------------------------------

  /// The gong by the PR board rings: someone hit it, a pull request merged (a harder stroke), or the
  /// task queue emptied (three strokes). From where it hangs, so you hear which way it is.
  void gong(GongWhy why) {
    if (!_ready) return;
    _count('gong.${why.wire}');
    final hit = why == GongWhy.hit;
    final name = switch (why) {
      GongWhy.hit => 'gong.hit',
      GongWhy.merged => 'gong.merged',
      GongWhy.queue => 'gong.queue',
    };
    _play(name, at: gongAt, ref: hit ? 4 : 8, rolloff: hit ? 0.6 : 0.45, bus: hit ? _Bus.ambience : _Bus.alerts);
  }

  // ---- Alerts ----------------------------------------------------------------------------------

  /// Two notes up when a worker is done, a three-note nudge when it needs input.
  void ding(Ding kind) {
    if (!_ready) return;
    _count(kind == Ding.done ? 'done' : 'needs_input');
    _play(kind == Ding.done ? 'ding.done' : 'ding.needsInput', bus: _Bus.alerts);
  }

  // ---- The jukebox and the DJ -------------------------------------------------------------------

  /// What the jukebox on your floor plays, or null for nothing.
  void setJukebox(JukeboxPlay? play) {
    final error = _music.setJukebox(play);
    if (error != null) onMusicError?.call(error);
    if (play != null && _ready) _count(_music.isStream ? 'stream' : 'tune');
  }

  /// Whether the jukebox's tune is playing (for checks).
  bool get tunePlaying => _music.tunePlaying;

  /// Your own music volume, 0–1, apart from the office sounds'.
  void setMusicVolume(double volume, bool muted) => _music.setVolume(volume, muted);

  /// 1 on each beat of the tune, falling to 0 before the next, for the jukebox's lights.
  double beat() => _music.beat();

  /// Up on the roof (true), or inside on a floor: the office's hum gives way to the wind and the city.
  void setOutdoors(bool on) => _outdoors = on;

  /// The DJ's set on the roof, [clock] saying how far into it it is (see djTime); null stops it.
  void setDj(double Function()? clock) {
    final started = _music.setDj(clock);
    if (started) _count('dj');
  }

  /// Someone at the DJ booth blew the air horn.
  void horn() {
    if (_music.horn()) _count('horn');
  }

  /// A drink poured at the bar: ice into the glass, a splash, and a clink.
  void pour(double x, double y, double z) {
    if (!_ready) return;
    _count('pour');
    _play('pour', at: Pos(x, y, z), ref: 1.2, rolloff: 1);
  }

  /// Hic! One too many.
  void hiccup() {
    if (!_ready) return;
    _count('hiccup');
    _play('hiccup');
  }

  /// Where the DJ's speakers are (for checks).
  static const Pos djAt = Pos(DjBooth.x, 2.2, DjBooth.z);
}
