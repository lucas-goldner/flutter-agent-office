// Headless checks of the synthesis: renders a few of the office's voices and a bar of the jukebox
// through an OfflineAudioContext and measures them, since a headless browser can't hear anything.

import 'dart:js_interop';
import 'dart:math' as math;

import 'package:web/web.dart' as web;

import 'package:office_shared/protocol.dart' show GongWhy;

import 'dnb.dart';
import 'dnb_score.dart';
import 'music.dart';
import 'score.dart';
import 'sound_web.dart';
import 'web_audio.dart';

const int _sampleRate = 48000;

/// Renders `seconds` of what `play` schedules into a fresh OfflineAudioContext; returns its RMS
/// over both channels.
Future<double> renderRms(double seconds, void Function(web.OfflineAudioContext ctx) play) async {
  final ctx = web.OfflineAudioContext(2.toJS, (_sampleRate * seconds).round(), _sampleRate);
  play(ctx);
  final out = await ctx.startRendering().toDart;
  var sum = 0.0;
  var n = 0;
  for (var ch = 0; ch < out.numberOfChannels; ch++) {
    final r = rms(out.getChannelData(ch).toDart);
    sum += r * r * out.length;
    n += out.length;
  }
  return n == 0 ? 0 : math.sqrt(sum / n);
}

/// The office's voices, each rendered on its own (over the room tone every OfficeSound starts),
/// and a bar of each part of a tune: name → RMS.
Future<Map<String, double>> runAudioChecks() async {
  OfficeSound office(web.OfflineAudioContext ctx) => OfficeSound.offline(ctx);
  final out = <String, double>{};
  out['room tone'] = await renderRms(2, (ctx) => office(ctx));
  out['ding done'] = await renderRms(2, (ctx) => office(ctx).ding(Ding.done));
  out['ding needs_input'] = await renderRms(2, (ctx) => office(ctx).ding(Ding.needsInput));
  out['gong merged'] = await renderRms(4, (ctx) => office(ctx).gong(GongWhy.merged));
  out['coffee'] = await renderRms(6, (ctx) => office(ctx).coffee());
  out['bark x3'] = await renderRms(2, (ctx) => office(ctx).bark(0, -2, 3));
  out['steps x6'] = await renderRms(2, (ctx) {
    final s = office(ctx);
    for (var i = 0; i < 6; i++) {
      s.step();
    }
  });
  out['thunder'] = await renderRms(7, (ctx) => office(ctx).thunder(0.2, 1));
  // A bar of rainy-window: the keys alone (bar 0), and everything with the melody (bar 8).
  final score = Score('rainy-window');
  final bar = score.step * 16;
  for (final (name, from) in const [('music bar 0 (keys)', 0), ('music bar 8 (all)', 8)]) {
    out[name] = await renderRms(bar + 1, (ctx) {
      TunePlayer(ctx, ctx.destination, 'rainy-window').prerender(from * 16, from * 16 + 16);
    });
  }
  // The DJ on the roof: a bar of the intro (hats), of the first drop, and the air horn and a pour.
  for (final (name, bar) in const [('dj bar 0 (intro)', 0), ('dj bar 24 (drop)', 24), ('dj bar 64 (breakdown)', 64)]) {
    out[name] = await renderRms(djBar + 1, (ctx) => DjPlayer(ctx, ctx.destination).prerender(bar * 16, bar * 16 + 16));
  }
  out['dj horn'] = await renderRms(2, (ctx) => DjPlayer(ctx, ctx.destination).horn(0.05));
  out['pour'] = await renderRms(2, (ctx) => office(ctx).pour(0, 1, 0));
  out['hiccup'] = await renderRms(1, (ctx) => office(ctx).hiccup());
  return out;
}

/// A few of the tune maths' numbers, to compare the web build's integer maths with the VM's and the TS's.
String scoreFingerprint() {
  final r = mulberry(7);
  return 'hash(12345,67)=${hash(12345, 67)} mulberry(7)=${r()},${r()} '
      'melody(coffee-break)=${Score('coffee-break').melody.first}';
}
