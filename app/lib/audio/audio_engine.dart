// What the desktop app's sound plays through: an interface over SoLoud (package:flutter_soloud), so
// sound_native.dart can be tested with a fake one (SoLoud's native library doesn't load under
// `flutter test`). Sources are PCM rendered by synth.dart; voices are playing instances of them.
//
// Native only: sound.dart exports sound_native.dart (and so this) only off the web.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_soloud/flutter_soloud.dart' as so;

import 'synth.dart' show interleaved, wavChannels;

/// A sound engine: loads PCM, plays it, and moves what's playing about.
abstract interface class AudioEngine {
  /// Starts the engine at [sampleRate] (stereo out). Throws if there's no audio here.
  Future<void> init(int sampleRate);

  /// One Float32List per channel (1 or 2) at [sampleRate]; returns a source id.
  Future<int> load(List<Float32List> channels, int sampleRate, String name);

  /// A source fed as it plays (a stream of [channels] at [sampleRate]); [lowpass] gives it a
  /// filter whose cutoff [setLowpass] moves.
  int openStream(int sampleRate, int channels, {bool lowpass = false});

  /// Appends one Float32List per channel to a stream.
  void feed(int stream, List<Float32List> channels);

  /// A stream of MP3 or Ogg (Opus, Vorbis), decoded as it's fed: internet radio.
  int openCompressedStream();

  /// Appends encoded bytes to a compressed stream.
  void feedBytes(int stream, Uint8List bytes);

  /// No more is coming: the stream ends when it's played what it has.
  void endStream(int stream);

  /// Seconds of a stream played so far.
  double played(int stream);

  /// Starts [source]: [volume], and the gains of the left and right channels (equal power: 0.707 each
  /// for the middle of a panner; 1, 1 for a sound that isn't anywhere). Returns a voice id, or -1.
  int play(
    int source, {
    double volume = 1,
    double left = 1,
    double right = 1,
    double speed = 1,
    bool loop = false,
    double seek = 0,
    bool paused = false,
  });

  void setVolume(int voice, double volume);
  void setPan(int voice, double left, double right);
  void setSpeed(int voice, double speed);
  void setPaused(int voice, bool paused);
  void setLowpass(int stream, int voice, double hz);

  /// Fades [voice] out over [seconds], then stops it.
  void fadeOut(int voice, double seconds);
  void stop(int voice);
  bool alive(int voice);

  /// Lets go of a source (stopping its voices).
  void free(int source);

  /// Shuts the engine down.
  void shutdown();
}

/// SoLoud, through package:flutter_soloud.
class SoLoudEngine implements AudioEngine {
  so.SoLoud get _s => so.SoLoud.instance;
  final Map<int, so.AudioSource> _sources = {};
  int _nextSource = 1;
  int _rate = 44100;

  @override
  Future<void> init(int sampleRate) async {
    _rate = sampleRate;
    if (!_s.isInitialized) {
      await _s.init(sampleRate: sampleRate, bufferSize: 1024, channels: so.Channels.stereo);
    }
    _s.setMaxActiveVoiceCount(96);
    // A safety net against clipping when the whole office goes off at once.
    try {
      final lim = _s.filters.limiterFilter;
      lim.activate();
      lim.threshold.value = -2;
      lim.outputCeiling.value = -0.5;
    } catch (e) {
      debugPrint('sound: no limiter ($e)');
    }
  }

  @override
  Future<int> load(List<Float32List> channels, int sampleRate, String name) async {
    final src = await _s.loadMem('$name.wav', wavChannels(channels, sampleRate));
    final id = _nextSource++;
    _sources[id] = src;
    return id;
  }

  @override
  int openStream(int sampleRate, int channels, {bool lowpass = false}) {
    final src = _s.setBufferStream(
      bufferingType: so.BufferingType.released,
      bufferingTimeNeeds: 0.25,
      sampleRate: sampleRate,
      channels: channels == 2 ? so.Channels.stereo : so.Channels.mono,
      format: so.BufferType.f32le,
      maxBufferSizeDuration: const Duration(hours: 12),
    );
    if (lowpass) src.filters.biquadFilter.activate();
    final id = _nextSource++;
    _sources[id] = src;
    return id;
  }

  @override
  void feed(int stream, List<Float32List> channels) {
    final src = _sources[stream];
    if (src == null) return;
    _s.addAudioDataStream(src, interleaved(channels));
  }

  @override
  int openCompressedStream() {
    final src = _s.setBufferStream(
      bufferingType: so.BufferingType.released,
      bufferingTimeNeeds: 1,
      sampleRate: _rate,
      channels: so.Channels.stereo,
      format: so.BufferType.auto,
      maxBufferSizeBytes: 1 << 30,
    );
    final id = _nextSource++;
    _sources[id] = src;
    return id;
  }

  @override
  void feedBytes(int stream, Uint8List bytes) {
    final src = _sources[stream];
    if (src != null) _s.addAudioDataStream(src, bytes);
  }

  @override
  void endStream(int stream) {
    final src = _sources[stream];
    if (src != null) _quietly(() => _s.setDataIsEnded(src));
  }

  @override
  double played(int stream) {
    final src = _sources[stream];
    if (src == null) return 0;
    return _s.getStreamTimeConsumed(src).inMicroseconds / 1e6;
  }

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
    final src = _sources[source];
    if (src == null) return -1;
    try {
      final h = _s.play(src, volume: volume, paused: true, looping: loop);
      _s.setPanAbsolute(h, left, right);
      if (speed != 1) _s.setRelativePlaySpeed(h, speed);
      if (seek > 0) _s.seek(h, Duration(microseconds: (seek * 1e6).round()));
      if (!paused) _s.setPause(h, false);
      return h.id;
    } catch (e) {
      debugPrint('sound: $e');
      return -1;
    }
  }

  so.SoundHandle _h(int voice) => so.SoundHandle(voice);

  void _quietly(void Function() f) {
    try {
      f();
    } catch (_) {
      // The voice has finished.
    }
  }

  @override
  void setVolume(int voice, double volume) => _quietly(() => _s.setVolume(_h(voice), volume));

  @override
  void setPan(int voice, double left, double right) => _quietly(() => _s.setPanAbsolute(_h(voice), left, right));

  @override
  void setSpeed(int voice, double speed) => _quietly(() => _s.setRelativePlaySpeed(_h(voice), speed));

  @override
  void setPaused(int voice, bool paused) => _quietly(() => _s.setPause(_h(voice), paused));

  @override
  void setLowpass(int stream, int voice, double hz) {
    final src = _sources[stream];
    if (src == null) return;
    _quietly(() {
      final f = src.filters.biquadFilter;
      f.frequency(soundHandle: _h(voice)).value = hz.clamp(10, 16000).toDouble();
      // Web Audio's Q of 0.5 dB: a resonance of about 1.06.
      f.resonance(soundHandle: _h(voice)).value = 1.06;
    });
  }

  @override
  void fadeOut(int voice, double seconds) => _quietly(() {
    final d = Duration(microseconds: (seconds * 1e6).round());
    _s.fadeVolume(_h(voice), 0, d);
    _s.scheduleStop(_h(voice), d);
  });

  @override
  void stop(int voice) => _quietly(() => unawaited(_s.stop(_h(voice))));

  @override
  bool alive(int voice) => _s.isInitialized && _s.getIsValidVoiceHandle(_h(voice));

  @override
  void free(int source) {
    final src = _sources.remove(source);
    if (src != null) unawaited(_s.disposeSource(src).catchError((Object _) {}));
  }

  @override
  void shutdown() {
    _sources.clear();
    if (_s.isInitialized) _s.deinit();
  }

  /// The sample rate it was started at.
  int get sampleRate => _rate;
}
