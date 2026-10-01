// The web half of the desktop app's sound parity check: renders the office's voices and bars of music
// through Web Audio's OfflineAudioContext (sound_web.dart, music.dart, dnb.dart) and prints each one's
// RMS and spectral centroid, for dev/audio_parity.py to compare with the Dart synth's renders of the
// same thing (test/audio/parity_dart.dart).
//
//   flutter build web --release --no-web-resources-cdn -t lib/dev/audio_parity.dart -o build/audio_parity

// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:math' as math;
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:web/web.dart' as web;

import 'package:office_shared/protocol.dart' show GongWhy;

import '../audio/dnb.dart';
import '../audio/dnb_score.dart' show djBar;
import '../audio/music.dart';
import '../audio/samples.dart' show OfficeSamples, TuneSamples;
import '../audio/score.dart';
import '../audio/web_audio.dart' show audioBuffer;
import '../audio/sound_web.dart';
import '../audio/synth.dart' show peakOf, rmsOf, spectralCentroid;
import 'audio_parity_cases.dart';

const int _sr = 48000;

/// Renders what [play] schedules: (left, right).
Future<(Float32List, Float32List)> _render(double seconds, void Function(web.OfflineAudioContext ctx) play) async {
  final ctx = web.OfflineAudioContext(2.toJS, (_sr * seconds).round(), _sr);
  play(ctx);
  final out = await ctx.startRendering().toDart;
  return (out.getChannelData(0).toDart, out.getChannelData(1).toDart);
}

void _report(String name, (Float32List, Float32List) lr) {
  final (l, r) = lr;
  final mono = Float32List(l.length);
  for (var i = 0; i < l.length; i++) {
    mono[i] = (l[i] + r[i]) / 2;
  }
  print(
    'PARITY $name left=${rmsOf(l).toStringAsExponential(5)} right=${rmsOf(r).toStringAsExponential(5)} '
    'mono=${rmsOf(mono).toStringAsExponential(5)} centroid=${spectralCentroid(mono, _sr).toStringAsFixed(1)} '
    'peak=${math.max(peakOf(l), peakOf(r)).toStringAsFixed(4)}',
  );
}

/// How long the office runs before a case's sound: the master volume and the compressor have settled,
/// as they have in the app by the time anything plays.
const double _settle = 0.6;

/// Starts an office at 0, plays the case's sound into it [_settle] seconds in, and returns what follows.
Future<(Float32List, Float32List)> _renderOffice(String name, double seconds, void Function(OfficeSound)? play) async {
  final ctx = web.OfflineAudioContext(2.toJS, (_sr * (_settle + seconds)).round(), _sr);
  final s = _office(ctx, name);
  if (play != null) {
    unawaited(
      ctx.suspend(_settle).toDart.then((_) {
        play(s);
        unawaited(ctx.resume().toDart);
      }),
    );
  }
  final out = await ctx.startRendering().toDart;
  final from = (_settle * _sr).round();
  return (
    Float32List.sublistView(out.getChannelData(0).toDart, from),
    Float32List.sublistView(out.getChannelData(1).toDart, from),
  );
}

/// An office that renders into [ctx], heard from where the case says.
OfficeSound _office(web.OfflineAudioContext ctx, String name) {
  final (_, l) = parityCases[name]!;
  final lis = ctx.listener;
  lis.positionX.value = l.x;
  lis.positionY.value = l.y;
  lis.positionZ.value = l.z;
  lis.forwardX.value = l.fx;
  lis.forwardY.value = 0;
  lis.forwardZ.value = l.fz;
  return OfficeSound.offline(ctx);
}

/// Calibration: Web Audio's oscillators, compressors and convolver, on simple inputs.
Future<void> _calibrate() async {
  for (final type in const ['sine', 'square', 'sawtooth', 'triangle']) {
    for (final f in const [110.0, 440.0, 1500.0]) {
      final (l, _) = await _render(1, (ctx) {
        final o = ctx.createOscillator()
          ..type = type
          ..frequency.value = f;
        o.connect(ctx.destination);
        o.start();
      });
      print('CAL osc.$type.${f.round()} rms=${rmsOf(l).toStringAsFixed(5)} peak=${peakOf(l).toStringAsFixed(5)}');
    }
  }
  for (final (name, t, k, r, a, rel) in const [
    ('office', -14.0, 12.0, 4.0, 0.004, 0.25),
    ('tune', -20.0, 30.0, 3.0, 0.01, 0.2),
    ('dj', -16.0, 8.0, 4.0, 0.005, 0.12),
  ]) {
    for (final amp in const [0.01, 0.1, 0.2, 0.4, 0.8]) {
      final (l, _) = await _render(2, (ctx) {
        final o = ctx.createOscillator()..frequency.value = 220;
        final g = ctx.createGain()..gain.value = amp;
        final c = ctx.createDynamicsCompressor();
        c.threshold.value = t;
        c.knee.value = k;
        c.ratio.value = r;
        c.attack.value = a;
        c.release.value = rel;
        o.connect(g);
        g.connect(c);
        c.connect(ctx.destination);
        o.start();
      });
      print('CAL comp.$name.$amp rms=${rmsOf(Float32List.sublistView(l, _sr)).toStringAsFixed(5)}');
    }
  }
  final (cl, cr) = await _render(2, (ctx) {
    final conv = ctx.createConvolver()..buffer = audioBuffer(ctx, TuneSamples(_sr, math.Random(5)).room);
    final b = ctx.createBuffer(1, 1, _sr);
    b.copyToChannel(Float32List.fromList([1]).toJS, 0);
    final src = ctx.createBufferSource()..buffer = b;
    src.connect(conv);
    conv.connect(ctx.destination);
    src.start();
  });
  print(
    'CAL conv rms=${rmsOf(cl).toStringAsExponential(5)},${rmsOf(cr).toStringAsExponential(5)} peak=${peakOf(cl).toStringAsExponential(4)}',
  );
}

/// The office's samples, and one played through an AudioBufferSourceNode.
Future<void> _samples() async {
  for (var i = 0; i < 3; i++) {
    final o = OfficeSamples(_sr, math.Random(3 + i));
    final step = o.steps.first;
    final (l, _) = await _render(0.3, (ctx) {
      final src = ctx.createBufferSource()..buffer = audioBuffer(ctx, [step]);
      src.connect(ctx.destination);
      src.start();
    });
    print(
      'CAL samples.$i step=${rmsOf(step).toStringAsFixed(5)} played=${rmsOf(Float32List.sublistView(l, 0, step.length)).toStringAsFixed(5)} '
      'key=${rmsOf(o.keys.first).toStringAsFixed(5)} rustle=${rmsOf(o.rustle).toStringAsFixed(5)} brown=${rmsOf(o.brown).toStringAsFixed(5)}',
    );
  }
}

Future<void> _run() async {
  await _samples();
  await _calibrate();
  final near = parityNear;
  final cases = <(String, void Function(OfficeSound))>[
    ('room', (s) {}),
    ('ding.done', (s) => s.ding(Ding.done)),
    ('ding.needsInput', (s) => s.ding(Ding.needsInput)),
    ('gong.merged', (s) => s.gong(GongWhy.merged)),
    ('gong.hit', (s) => s.gong(GongWhy.hit)),
    ('gong.queue', (s) => s.gong(GongWhy.queue)),
    ('coffee', (s) => s.coffee()),
    ('bark3', (s) => s.bark(near.x, near.z, 3)),
    ('yip', (s) => s.yip(near.x, near.z)),
    (
      'steps6',
      (s) {
        for (var i = 0; i < 6; i++) {
          s.step();
        }
      },
    ),
    ('stepAt', (s) => s.stepAt(0, -2)),
    ('thunder', (s) => s.thunder(0.2, 1)),
    ('pour', (s) => s.pour(0, 1, -2)),
    ('hiccup', (s) => s.hiccup()),
    ('arcade.clear3', (s) => s.arcade('clear', 3)),
    ('arcade.over', (s) => s.arcade('over')),
    ('ball.bounce', (s) => s.ball('bounce', 0, 1, -2, 5)),
    ('ball.score', (s) => s.ball('score', 0, 1, -2, 5)),
  ];
  for (final (name, play) in cases) {
    final (seconds, _) = parityCases[name]!;
    // Most are random in places: several of each.
    // The short ones are lost in the room's rumble unless there are plenty of them.
    for (var i = 0; i < (seconds < 1 ? 40 : (seconds < 2 ? 24 : 8)); i++) {
      _report(name, await _renderOffice(name, seconds, play));
      // The room tone alone, over the same stretch, to take away.
      if (name != 'room') _report('$name~room', await _renderOffice(name, seconds, null));
    }
  }
  // Bars of the jukebox and the DJ, straight into the destination (no panner).
  final score = Score('rainy-window');
  final bar = score.step * 16;
  for (final from in const [0, 8]) {
    _report(
      'tune.rainy-window.$from',
      await _render(bar + 1, (ctx) {
        TunePlayer(ctx, ctx.destination, 'rainy-window').prerender(from * 16, from * 16 + 16);
      }),
    );
  }
  for (final b in const [0, 24, 64, 88]) {
    _report('dj.$b', await _render(djBar + 1, (ctx) => DjPlayer(ctx, ctx.destination).prerender(b * 16, b * 16 + 16)));
  }
  _report('dj.horn', await _render(3, (ctx) => DjPlayer(ctx, ctx.destination).horn(1.3)));
  print('PARITY done');
}

void main() {
  unawaited(_run());
  runApp(const Center(child: Text('audio parity', textDirection: TextDirection.ltr)));
}
