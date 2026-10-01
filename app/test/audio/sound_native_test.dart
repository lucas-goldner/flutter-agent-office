import 'dart:typed_data';

import 'package:agent_office/audio/audio_engine.dart';
import 'package:agent_office/audio/sound_model.dart';
import 'package:agent_office/audio/sound_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart' show GongWhy;

/// Stands in for SoLoud: remembers what's loaded and what plays.
class FakeEngine implements AudioEngine {
  final Map<int, (String, List<Float32List>)> sources = {};
  final Map<int, ({int source, double volume, double left, double right, double speed, bool loop, bool paused})>
  voices = {};
  final List<String> started = [];
  final Map<int, List<Float32List>> streamed = {};
  final Map<int, double> lowpass = {};
  int _next = 1;
  bool up = false;
  bool down = false;

  @override
  Future<void> init(int sampleRate) async => up = true;

  @override
  Future<int> load(List<Float32List> channels, int sampleRate, String name) async {
    final id = _next++;
    sources[id] = (name, channels);
    return id;
  }

  @override
  int openStream(int sampleRate, int channels, {bool lowpass = false}) {
    final id = _next++;
    sources[id] = ('stream', []);
    streamed[id] = [for (var c = 0; c < channels; c++) Float32List(0)];
    return id;
  }

  @override
  void feed(int stream, List<Float32List> channels) {
    final had = streamed[stream]!;
    streamed[stream] = [
      for (var c = 0; c < channels.length; c++) Float32List.fromList([...had[c], ...channels[c]]),
    ];
  }

  double playedSeconds = 0;

  @override
  double played(int stream) => playedSeconds;

  @override
  int play(
    int source, {
    double volume = 1,
    double left = 1,
    double right = 1,
    double speed = 1,
    bool loop = false,
    double seek = 0,
    bool paused = false,
  }) {
    final id = 1000 + _next++;
    voices[id] = (source: source, volume: volume, left: left, right: right, speed: speed, loop: loop, paused: paused);
    started.add(sources[source]!.$1);
    return id;
  }

  void _set(int voice, {double? volume, double? left, double? right, double? speed, bool? paused}) {
    final v = voices[voice];
    if (v == null) return;
    voices[voice] = (
      source: v.source,
      volume: volume ?? v.volume,
      left: left ?? v.left,
      right: right ?? v.right,
      speed: speed ?? v.speed,
      loop: v.loop,
      paused: paused ?? v.paused,
    );
  }

  @override
  void setVolume(int voice, double volume) => _set(voice, volume: volume);
  @override
  void setPan(int voice, double left, double right) => _set(voice, left: left, right: right);
  @override
  void setSpeed(int voice, double speed) => _set(voice, speed: speed);
  @override
  void setPaused(int voice, bool paused) => _set(voice, paused: paused);
  @override
  void setLowpass(int stream, int voice, double hz) => lowpass[voice] = hz;
  @override
  void fadeOut(int voice, double seconds) => voices.remove(voice);
  @override
  void stop(int voice) => voices.remove(voice);
  @override
  bool alive(int voice) => voices.containsKey(voice);
  @override
  void free(int source) => sources.remove(source);
  @override
  void shutdown() => down = true;

  /// The voices playing [name].
  Iterable<({int source, double volume, double left, double right, double speed, bool loop, bool paused})> playing(
    String name,
  ) => voices.values.where((v) => sources[v.source]?.$1 == name);
}

/// Waits (for real: the banks render in background isolates) until [done].
Future<void> until(bool Function() done, {int seconds = 60}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!done() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
  expect(done(), isTrue);
}

Future<void> wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  const long = Timeout(Duration(minutes: 3));

  test('under flutter test, with no engine given, it stays silent', () {
    final s = OfficeSound();
    expect(s.state, 'unavailable');
    s.gong(GongWhy.merged);
    s.ding(Ding.done);
    s.update(const SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1));
    expect(s.played, isEmpty);
    s.dispose();
  });

  test('the gong, the dings and steps play, from where they are', timeout: long, () async {
    final e = FakeEngine();
    final s = OfficeSound(engine: e)..setVolume(1, false);
    await until(() => e.sources.values.any((v) => v.$1 == 'gong.queue'));
    expect(s.state, 'running');
    // Let the master volume ease up.
    await wait(400);

    // Standing west of the gong, facing north: it's to your right.
    s.update(SoundListener(x: gongAt.x - 3, y: 1.4, z: gongAt.z, fx: 0, fz: -1));
    for (final why in GongWhy.values) {
      s.gong(why);
    }
    expect(e.started, contains('gong.queue'));
    expect(e.started.where((n) => n.startsWith('gong.merged.')), hasLength(1));
    expect(e.started.where((n) => n.startsWith('gong.hit.')), hasLength(1));
    expect(e.started.where((n) => n.startsWith('gong.')), hasLength(3));
    final merged = e.voices.values.firstWhere((v) => e.sources[v.source]!.$1.startsWith('gong.merged'));
    expect(merged.right, greaterThan(0.95));
    expect(merged.left, lessThan(0.3));
    expect(merged.volume, greaterThan(0.3));
    expect(s.played, containsPair('gong.merged', 1));
    expect(s.played, containsPair('gong.hit', 1));
    expect(s.played, containsPair('gong.queue', 1));

    s.ding(Ding.done);
    s.ding(Ding.needsInput);
    expect(e.started, containsAll(['ding.done', 'ding.needsInput']));
    final ding = e.playing('ding.done').single;
    expect((ding.left, ding.right), (1, 1));

    s.step();
    s.step(StepKind.land);
    s.stepAt(gongAt.x - 3, gongAt.z + 5);
    expect(e.started.where((n) => n.startsWith('step.')), hasLength(3));
    expect(s.played, containsPair('step', 1));
    expect(s.played, containsPair('land', 1));

    // Muted, everything goes quiet.
    s.setVolume(1, true);
    await wait(400);
    s.update(SoundListener(x: gongAt.x - 3, y: 1.4, z: gongAt.z, fx: 0, fz: -1));
    expect(e.voices.values.where((v) => v.volume > 0.001), isEmpty);
    s.dispose();
    expect(e.down, isTrue);
  });

  test('the room hums, typists type, rain falls, and the roof is windy', timeout: long, () async {
    final e = FakeEngine();
    final s = OfficeSound(engine: e)..setVolume(1, false);
    await until(() => e.started.contains('room'));
    expect(e.started, containsAll(['room', 'roof', 'fridge']));
    await until(() => e.sources.values.any((v) => v.$1 == 'typing.2'));
    const you = SoundListener(x: 0, y: 1.4, z: 0, fx: 0, fz: -1);
    s.setTyping('w1', 2, -3, true);
    s.update(you);
    final typing = e.playing('typing.0').followedBy(e.playing('typing.1')).followedBy(e.playing('typing.2'));
    expect(typing, hasLength(1));
    expect(typing.single.loop, isTrue);
    expect(typing.single.paused, isFalse);
    s.setTyping('w1', 2, -3, false);
    expect(e.voices.values.where((v) => e.sources[v.source]!.$1.startsWith('typing') && !v.paused), isEmpty);

    s.setWeather(1, 0);
    s.update(you);
    await wait(1500);
    s.update(you);
    final rain = e.playing('rain.office').single;
    expect(rain.volume, greaterThan(0.02));

    // Up on the roof, the room's hum fades and the wind comes up.
    double vol(String name) => e.playing(name).single.volume;
    final roomIn = vol('room');
    s.setOutdoors(true);
    await wait(1500);
    s.update(you);
    expect(vol('room'), lessThan(roomIn / 5));
    expect(vol('roof'), greaterThan(roomIn / 5));
    s.dispose();
  });
}
