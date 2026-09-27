// A page to hear the office's sounds: a button plays each in turn and starts the jukebox.
// With ?check=1 it renders a few voices and bars of music offline and prints their RMS instead
// (headless Chromium can't hear).
//
//   flutter build web --release --no-web-resources-cdn -t lib/dev/preview_audio.dart -o build/preview_audio

// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../audio/audio_check.dart';
import '../audio/sound.dart';
import 'package:office_shared/layout.dart';
import 'package:office_shared/protocol.dart' show GongWhy;
import '../state/store.dart' show nowMs;
import '../ui/theme.dart';

void main() {
  if (Uri.base.queryParameters['check'] == '1') {
    unawaited(_check());
  }
  runApp(MaterialApp(debugShowCheckedModeBanner: false, theme: officeTheme(), home: const _AudioPreview()));
}

Future<void> _check() async {
  print('audio check: ${scoreFingerprint()}');
  final results = await runAudioChecks();
  results.forEach((name, rms) => print('RMS $name = ${rms.toStringAsFixed(5)}'));
  print('audio check done');
}

class _AudioPreview extends StatefulWidget {
  const _AudioPreview();

  @override
  State<_AudioPreview> createState() => _AudioPreviewState();
}

class _AudioPreviewState extends State<_AudioPreview> with SingleTickerProviderStateMixin {
  final OfficeSound _sound = OfficeSound();
  late final Ticker _ticker;
  String _now = '';
  Timer? _script;

  /// Where you stand: by the lounge, facing the jukebox, near the desks and the kitchen's far end.
  static const _you = SoundListener(x: 12, y: 1.4, z: 4, fx: 1, fz: 0.2);

  @override
  void initState() {
    super.initState();
    _sound.setVolume(0.8, false);
    _sound.setMusicVolume(0.7, false);
    _ticker = createTicker((_) {
      _sound.update(_you);
      if (mounted) setState(() {});
    })..start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _script?.cancel();
    _sound.dispose();
    super.dispose();
  }

  /// Each sound in turn, a couple of seconds apart, then the jukebox.
  late final List<(String, void Function())> _steps = [
    ('ding: done', () => _sound.ding(Ding.done)),
    ('ding: needs input', () => _sound.ding(Ding.needsInput)),
    ('footsteps', () {
      for (var i = 0; i < 4; i++) {
        Timer(Duration(milliseconds: 380 * i), _sound.step);
      }
    }),
    ('landing a jump', () => _sound.step(StepKind.land)),
    ("someone else's steps", () {
      for (var i = 0; i < 4; i++) {
        Timer(Duration(milliseconds: 400 * i), () => _sound.stepAt(8 + i * 0.6, 2));
      }
    }),
    ('a worker typing', () => _sound.setTyping('w1', desks.first.x, desks.first.z, true)),
    ('the coffee machine', _sound.coffee),
    ('the dog barks', () => _sound.bark(10, 6, 3)),
    ('the dog yips', () => _sound.yip(10, 6)),
    ('the gong: hit', () => _sound.gong(GongWhy.hit)),
    ('the gong: merged', () => _sound.gong(GongWhy.merged)),
    ('the gong: queue', () => _sound.gong(GongWhy.queue)),
    ('rain', () => _sound.setWeather(0.8, 0)),
    ('thunder', () => _sound.thunder(0.3, 1)),
    ('night: crickets', () {
      _sound.removeTypist('w1');
      _sound.setWeather(0, 1);
    }),
    ('the jukebox: rainy-window', () {
      _sound.setWeather(0, 0);
      _sound.setJukebox(JukeboxPlay(track: 'rainy-window', startedAt: 1, since: nowMs()));
    }),
  ];

  void _playAll() {
    _sound.unlock();
    _script?.cancel();
    var i = 0;
    void next() {
      if (i >= _steps.length) return;
      final (name, play) = _steps[i++];
      setState(() => _now = name);
      play();
      _script = Timer(Duration(milliseconds: name.startsWith('the coffee') || name.startsWith('the gong: queue') ? 6000 : 2500), next);
    }

    next();
  }

  void _stopJukebox() => _sound.setJukebox(null);

  @override
  Widget build(BuildContext context) {
    final played = _sound.played.entries.map((e) => '${e.key} ${e.value}').join(' · ');
    return Scaffold(
      backgroundColor: Swatch.paper,
      body: Center(
        child: Panel(
          child: SizedBox(
            width: 520,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Office sounds', style: heavy(22)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    OfficeButton(label: 'Play every sound', onPressed: _playAll, kind: BtnKind.primary),
                    const SizedBox(width: 8),
                    OfficeButton(label: 'Stop the jukebox', onPressed: _stopJukebox),
                  ],
                ),
                const SizedBox(height: 12),
                Text('Audio: ${_sound.state} · now: ${_now.isEmpty ? '–' : _now}', style: heavy(14)),
                const SizedBox(height: 6),
                Text('Level ${_sound.level().toStringAsFixed(3)} · music ${_sound.musicLevel().toStringAsFixed(3)} · beat ${_sound.beat().toStringAsFixed(2)}',
                    style: heavy(13, color: Swatch.muted)),
                const SizedBox(height: 6),
                Text(played.isEmpty ? 'Nothing yet' : played, style: heavy(12, color: Swatch.muted, weight: FontWeight.w600)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
