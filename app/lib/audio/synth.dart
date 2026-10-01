// A small offline synthesizer: the parts of Web Audio the office's sounds are made of, in plain Dart,
// rendering to Float32List PCM. The desktop app plays what it renders through SoLoud (sound_native.dart);
// the web keeps Web Audio itself (sound_web.dart). Pure Dart, so it runs (and is tested) on the VM.
//
// The pieces follow Web Audio's own definitions, so a graph ported from sound_web.dart sounds the same:
// AudioParam automation (setValueAtTime, linear/exponential ramps, setTargetAtTime), oscillators that
// start at phase 0 like OscillatorNode's, BiquadFilterNode's formulas (Q in dB for lowpass/highpass),
// playback-rate resampling, a delay line, a convolver normalized like Chromium's, and a compressor with
// Chromium's knee and makeup gain.
//
// Times are seconds from the start of the buffer being rendered.

import 'dart:math' as math;
import 'dart:typed_data';

/// The sample rate the desktop app renders and plays at.
const int nativeSampleRate = 44100;

// ---- AudioParam --------------------------------------------------------------------------------------

enum _Ev { set, linear, exp, target }

class _Event {
  _Event(this.kind, this.time, this.value, [this.tc = 0]);

  final _Ev kind;
  final double time;
  final double value;
  final double tc;
}

/// An AudioParam's timeline: a value before anything's scheduled, then events in time order.
class Param {
  Param(this.value);

  /// The value before the first event (AudioParam.value with nothing scheduled).
  double value;
  final List<_Event> _events = [];

  bool get automated => _events.isNotEmpty;

  void _add(_Event e) {
    // Keep them in time order; an event at the same time as another goes after it, like Web Audio.
    var i = _events.length;
    while (i > 0 && _events[i - 1].time > e.time) {
      i--;
    }
    _events.insert(i, e);
    _cursor = 0;
  }

  void setValueAtTime(double v, double t) => _add(_Event(_Ev.set, t, v));
  void linearRampToValueAtTime(double v, double t) => _add(_Event(_Ev.linear, t, v));
  void exponentialRampToValueAtTime(double v, double t) => _add(_Event(_Ev.exp, t, v));
  void setTargetAtTime(double target, double t, double timeConstant) =>
      _add(_Event(_Ev.target, t, target, timeConstant));

  /// Ramps from 0 through (seconds after t0, value) points, like web_audio.dart's envelope().
  void envelope(double t0, List<(double, double)> points) {
    setValueAtTime(0, t0);
    for (final (dt, v) in points) {
      linearRampToValueAtTime(v, t0 + dt);
    }
  }

  // Where valueAt last was, so walking forward through time is cheap.
  int _cursor = 0;
  double _segStart = 0;
  double _segValue = 0;
  _Event? _holding; // a setTarget in progress, else a constant

  void _reset() {
    _cursor = 0;
    _segStart = double.negativeInfinity;
    _segValue = value;
    _holding = null;
  }

  double _held(double t) {
    final h = _holding;
    if (h == null) return _segValue;
    return h.value + (_segValue - h.value) * math.exp(-(t - h.time) / h.tc);
  }

  /// The value at time [t]. Fastest when called with increasing t.
  double valueAt(double t) {
    if (_events.isEmpty) return value;
    if (_cursor == 0 || t < _segStart) _reset();
    while (_cursor < _events.length) {
      final e = _events[_cursor];
      switch (e.kind) {
        case _Ev.set:
          if (t < e.time) return _held(t);
          _segValue = e.value;
          _segStart = e.time;
          _holding = null;
        case _Ev.target:
          if (t < e.time) return _held(t);
          _segValue = _held(e.time);
          _segStart = e.time;
          _holding = e.tc > 0 ? e : null;
          if (e.tc <= 0) _segValue = e.value;
        case _Ev.linear:
        case _Ev.exp:
          final t0 = _segStart.isFinite ? _segStart : 0.0;
          if (_holding != null) {
            // A ramp after setTarget starts from where the target curve has got to.
            _segValue = _held(t0);
            _holding = null;
          }
          final from = _segValue;
          if (t < e.time) {
            final span = e.time - t0;
            final k = span <= 0 ? 1.0 : ((t - t0) / span).clamp(0.0, 1.0);
            if (e.kind == _Ev.linear) return from + (e.value - from) * k;
            if (from == 0 || e.value == 0 || (from < 0) != (e.value < 0)) return from;
            return from * math.pow(e.value / from, k);
          }
          _segValue = e.value;
          _segStart = e.time;
      }
      _cursor++;
    }
    return _held(t);
  }

  /// The values for [n] samples from time [t0] at [sr].
  Float32List render(int n, int sr, [double t0 = 0]) {
    final out = Float32List(n);
    if (_events.isEmpty) {
      out.fillRange(0, n, value);
      return out;
    }
    _reset();
    for (var i = 0; i < n; i++) {
      out[i] = valueAt(t0 + i / sr);
    }
    return out;
  }
}

// ---- Sources -----------------------------------------------------------------------------------------

enum Wave { sine, square, sawtooth, triangle }

/// Web Audio's square and sawtooth are normalized to their band-limited peak (the Gibbs overshoot),
/// which leaves them this much quieter than the ideal waves (measured in Chromium: RMS 0.845 for a
/// square, 0.487 for a sawtooth).
const double _webNorm = 0.844;

double _polyBlep(double t, double dt) {
  if (t < dt) {
    final x = t / dt;
    return x + x - x * x - 1;
  }
  if (t > 1 - dt) {
    final x = (t - 1) / dt;
    return x * x + x + x + 1;
  }
  return 0;
}

/// An OscillatorNode from [start] to [stop] (seconds), [n] samples long in all: zero outside.
/// [freq] and [detune] (cents) may be automated; [fm] adds Hz per sample (an audio-rate input to
/// frequency). Square and sawtooth are band-limited (PolyBLEP), like Web Audio's wavetables.
Float32List osc(
  int n,
  int sr,
  Wave type,
  Param freq, {
  double start = 0,
  double? stop,
  Param? detune,
  Float32List? fm,
  Float32List? detuneMod,
}) {
  final out = Float32List(n);
  final i0 = math.max(0, (start * sr).ceil());
  final i1 = math.min(n, stop == null ? n : (stop * sr).ceil());
  var phase = 0.0;
  final fixedF = !freq.automated && fm == null && (detune == null || !detune.automated) && detuneMod == null;
  var f = freq.value * (detune == null ? 1 : math.pow(2, detune.value / 1200));
  for (var i = i0; i < i1; i++) {
    final t = i / sr;
    if (!fixedF) {
      var cents = detune == null ? 0.0 : detune.valueAt(t);
      if (detuneMod != null) cents += detuneMod[i];
      f = freq.valueAt(t);
      if (fm != null) f += fm[i];
      if (cents != 0) f *= math.pow(2, cents / 1200);
    }
    final dt = (f / sr).abs();
    double v;
    switch (type) {
      case Wave.sine:
        v = math.sin(2 * math.pi * phase);
      case Wave.square:
        v = phase < 0.5 ? 1 : -1;
        v += _polyBlep(phase, dt);
        v -= _polyBlep((phase + 0.5) % 1, dt);
      case Wave.sawtooth:
        final p = (phase + 0.5) % 1;
        v = 2 * p - 1 - _polyBlep(p, dt);
      case Wave.triangle:
        v = phase < 0.25 ? 4 * phase : (phase < 0.75 ? 2 - 4 * phase : 4 * phase - 4);
    }
    out[i] = type == Wave.square || type == Wave.sawtooth ? v * _webNorm : v;
    phase += f / sr;
    phase -= phase.floorToDouble();
  }
  return out;
}

/// A seeded uniform noise generator: -1..1.
class Noise {
  Noise([int seed = 1]) : _rng = math.Random(seed);

  final math.Random _rng;

  double next() => _rng.nextDouble() * 2 - 1;
}

/// White noise from [start] to [stop], [n] samples long in all.
Float32List noise(int n, int sr, math.Random rng, {double start = 0, double? stop}) {
  final out = Float32List(n);
  final i0 = math.max(0, (start * sr).ceil());
  final i1 = math.min(n, stop == null ? n : (stop * sr).ceil());
  for (var i = i0; i < i1; i++) {
    out[i] = rng.nextDouble() * 2 - 1;
  }
  return out;
}

/// An AudioBufferSourceNode: [buffer] played from [start] (seconds) at [rate] (which may be automated
/// through [rateParam]), from [offset] seconds into it, looping if [loop], until [stop]. Linear
/// interpolation between samples, as browsers do.
Float32List playBuffer(
  int n,
  int sr,
  Float32List buffer, {
  double start = 0,
  double? stop,
  double rate = 1,
  double offset = 0,
  bool loop = false,
}) {
  final out = Float32List(n);
  if (buffer.isEmpty) return out;
  final i0 = math.max(0, (start * sr).ceil());
  final i1 = math.min(n, stop == null ? n : (stop * sr).ceil());
  var pos = offset * sr + (i0 - start * sr) * rate;
  final len = buffer.length;
  for (var i = i0; i < i1; i++) {
    if (loop) {
      pos %= len;
    } else if (pos >= len - 1) {
      if (pos < len) out[i] = buffer[len - 1] * (len - pos);
      break;
    }
    final j = pos.floor();
    final fr = pos - j;
    final a = buffer[j];
    final b = buffer[(j + 1) % len];
    out[i] = a + (b - a) * fr;
    pos += rate;
  }
  return out;
}

// ---- Gain and mixing ---------------------------------------------------------------------------------

/// Multiplies [buf] by [gain]'s values, in place; returns it.
Float32List gain(Float32List buf, int sr, Param gain, [double t0 = 0]) {
  if (!gain.automated) return scale(buf, gain.value);
  for (var i = 0; i < buf.length; i++) {
    buf[i] *= gain.valueAt(t0 + i / sr);
  }
  return buf;
}

/// Multiplies [buf] by [k], in place; returns it.
Float32List scale(Float32List buf, double k) {
  if (k == 1) return buf;
  for (var i = 0; i < buf.length; i++) {
    buf[i] *= k;
  }
  return buf;
}

/// Adds [src] × [k] into [dst] from sample [at]; returns dst.
Float32List mixInto(Float32List dst, Float32List src, {int at = 0, double k = 1}) {
  final end = math.min(dst.length, at + src.length);
  for (var i = math.max(0, at); i < end; i++) {
    dst[i] += src[i - at] * k;
  }
  return dst;
}

/// Samples in [seconds].
int sampleCount(double seconds, int sr) => (seconds * sr).ceil();

// ---- Filters -----------------------------------------------------------------------------------------

enum BiquadType { lowpass, highpass, bandpass, peaking }

/// A BiquadFilterNode, stateful so a stream can run through it a chunk at a time.
class Biquad {
  Biquad(this.type, this.frequency, this.q, {this.gainDb = 0});

  Biquad.fixed(BiquadType type, double freq, double q, {double gainDb = 0})
    : this(type, Param(freq), q, gainDb: gainDb);

  final BiquadType type;
  final Param frequency;
  final double q;
  final double gainDb;
  double _b0 = 1, _b1 = 0, _b2 = 0, _a1 = 0, _a2 = 0;
  double _x1 = 0, _x2 = 0, _y1 = 0, _y2 = 0;
  double _lastF = -1;

  void _coefficients(double f, int sr) {
    _lastF = f;
    final nyq = sr / 2;
    final w0 = 2 * math.pi * f.clamp(1, nyq - 1) / sr;
    final cw = math.cos(w0), sw = math.sin(w0);
    double b0, b1, b2, a0, a1, a2;
    switch (type) {
      case BiquadType.lowpass:
      case BiquadType.highpass:
        // Web Audio takes these two's Q in dB.
        final alpha = sw / (2 * math.pow(10, q / 20));
        if (type == BiquadType.lowpass) {
          b0 = (1 - cw) / 2;
          b1 = 1 - cw;
          b2 = b0;
        } else {
          b0 = (1 + cw) / 2;
          b1 = -(1 + cw);
          b2 = b0;
        }
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
      case BiquadType.bandpass:
        final alpha = sw / (2 * q);
        b0 = alpha;
        b1 = 0;
        b2 = -alpha;
        a0 = 1 + alpha;
        a1 = -2 * cw;
        a2 = 1 - alpha;
      case BiquadType.peaking:
        final a = math.pow(10, gainDb / 40).toDouble();
        final alpha = sw / (2 * q);
        b0 = 1 + alpha * a;
        b1 = -2 * cw;
        b2 = 1 - alpha * a;
        a0 = 1 + alpha / a;
        a1 = -2 * cw;
        a2 = 1 - alpha / a;
    }
    _b0 = b0 / a0;
    _b1 = b1 / a0;
    _b2 = b2 / a0;
    _a1 = a1 / a0;
    _a2 = a2 / a0;
  }

  /// Filters [buf] in place (it starts at time [t0]); returns it.
  Float32List process(Float32List buf, int sr, [double t0 = 0]) {
    final auto = frequency.automated;
    if (!auto && _lastF != frequency.value) _coefficients(frequency.value, sr);
    for (var i = 0; i < buf.length; i++) {
      if (auto && i % 16 == 0) {
        final f = frequency.valueAt(t0 + i / sr);
        if (f != _lastF) _coefficients(f, sr);
      }
      final x = buf[i];
      final y = _b0 * x + _b1 * _x1 + _b2 * _x2 - _a1 * _y1 - _a2 * _y2;
      _x2 = _x1;
      _x1 = x;
      _y2 = _y1;
      _y1 = y.abs() < 1e-30 ? 0 : y;
      buf[i] = _y1;
    }
    return buf;
  }
}

/// Runs [buf] through a fixed biquad, in place.
Float32List biquad(Float32List buf, int sr, BiquadType type, double freq, double q) =>
    Biquad.fixed(type, freq, q).process(buf, sr);

/// Runs [buf] through a biquad whose frequency follows [freq], in place.
Float32List biquadAuto(Float32List buf, int sr, BiquadType type, Param freq, double q, [double t0 = 0]) =>
    Biquad(type, freq, q).process(buf, sr, t0);

// ---- Delay, shaper -----------------------------------------------------------------------------------

/// A DelayNode inside a feedback loop: out = x + echo, echo = delayed (x + echo × feedback). Stateful.
class FeedbackEcho {
  FeedbackEcho(double delay, int sr, this.feedback, this.level)
    : _line = Float32List(math.max(1, (delay * sr).round()));

  final Float32List _line;
  final double feedback;
  final double level;
  int _i = 0;

  /// Returns just the echoes of [buf] (× level), not the dry signal.
  Float32List wet(Float32List buf) {
    final out = Float32List(buf.length);
    for (var i = 0; i < buf.length; i++) {
      final d = _line[_i];
      out[i] = d * level;
      _line[_i] = buf[i] + d * feedback;
      _i = (_i + 1) % _line.length;
    }
    return out;
  }
}

/// A WaveShaperNode's curve lookup, in place.
Float32List shape(Float32List buf, Float32List curve) {
  final n = curve.length;
  for (var i = 0; i < buf.length; i++) {
    final v = (n - 1) * (buf[i].clamp(-1.0, 1.0) + 1) / 2;
    final j = v.floor();
    if (j >= n - 1) {
      buf[i] = curve[n - 1];
    } else {
      buf[i] = curve[j] + (curve[j + 1] - curve[j]) * (v - j);
    }
  }
  return buf;
}

// ---- Compressor --------------------------------------------------------------------------------------

/// A DynamicsCompressorNode, after Chromium's: the same knee curve and the same automatic makeup gain
/// (which makes quiet sounds louder than they went in), its 6 ms look-ahead, and a detector like its
/// own, which lets go within a few ms (so the lows, whose peaks are far apart, are squashed less than
/// the highs), followed by the attack and release.
class Compressor {
  Compressor({
    this.threshold = -24,
    this.knee = 30,
    this.ratio = 12,
    this.attack = 0.003,
    this.release = 0.25,
    required this.sr,
  }) {
    _linThreshold = _db2lin(threshold);
    _kneeThresholdDb = threshold + knee;
    _k = _kAtSlope(1 / ratio);
    _yKneeDb = _lin2db(_kneeCurve(_db2lin(_kneeThresholdDb), _k));
    makeup = math.pow(1 / _saturate(1, _k), 0.6).toDouble();
    _attackK = 1 - math.exp(-1 / (math.max(0.001, attack) * sr));
    _releaseK = 1 - math.exp(-1 / (math.max(0.001, release) * sr));
    _satFrames = 0.0025 * sr;
    final d = (0.006 * sr).round();
    _delayL = Float32List(d);
    _delayR = Float32List(d);
  }

  final double threshold, knee, ratio, attack, release;
  final int sr;
  late final double _linThreshold, _kneeThresholdDb, _k, _yKneeDb;
  late final double _attackK, _releaseK, _satFrames;
  late final Float32List _delayL, _delayR;
  int _di = 0;

  /// The gain Chromium adds back after compressing.
  late final double makeup;
  double _gain = 1;
  double _detector = 1;

  static double _db2lin(double db) => math.pow(10, db / 20).toDouble();
  static double _lin2db(double x) => x <= 0 ? -1000 : 20 * math.log(x) / math.ln10;

  double _kneeCurve(double x, double k) {
    if (x < _linThreshold) return x;
    return _linThreshold + (1 - math.exp(-k * (x - _linThreshold))) / k;
  }

  double _saturate(double x, double k) {
    if (x < _db2lin(_kneeThresholdDb)) return _kneeCurve(x, k);
    final y = _yKneeDb + (_lin2db(x) - _kneeThresholdDb) / ratio;
    return _db2lin(y);
  }

  double _slopeAt(double x, double k) {
    if (x < _linThreshold) return 1;
    final x2 = x * 1.001;
    final xDb = _lin2db(x), x2Db = _lin2db(x2);
    final yDb = _lin2db(_kneeCurve(x, k)), y2Db = _lin2db(_kneeCurve(x2, k));
    return (y2Db - yDb) / (x2Db - xDb);
  }

  double _kAtSlope(double desired) {
    final x = _db2lin(_kneeThresholdDb);
    var lo = 0.1, hi = 10000.0;
    var k = 5.0;
    for (var i = 0; i < 30; i++) {
      k = math.sqrt(lo * hi);
      final s = _slopeAt(x, k);
      if (s < desired) {
        hi = k;
      } else {
        lo = k;
      }
    }
    return k;
  }

  /// The static gain for a level [x] (linear), before makeup.
  double gainFor(double x) => x <= _linThreshold ? 1 : _saturate(x, _k) / x;

  /// Compresses [left] in place (one channel), or a stereo pair if [right] is given.
  void process(Float32List left, [Float32List? right]) {
    final n = _delayL.length;
    for (var i = 0; i < left.length; i++) {
      final l = left[i], r = right == null ? l : right[i];
      final a = math.max(l.abs(), r.abs());
      final att = a <= 0.0001 ? 1.0 : gainFor(a);
      if (att < _detector) {
        _detector = att;
      } else {
        final attDb = math.max(2.0, -_lin2db(att));
        final rate = _db2lin(attDb / _satFrames) - 1;
        _detector = math.min(1.0, _detector + (att - _detector) * rate);
      }
      _gain += (_detector - _gain) * (_detector < _gain ? _attackK : _releaseK);
      final g = _gain * makeup;
      // The look-ahead: what comes out is 6 ms old.
      final dl = _delayL[_di], dr = _delayR[_di];
      _delayL[_di] = l;
      _delayR[_di] = r;
      _di = (_di + 1) % n;
      left[i] = dl * g;
      if (right != null) right[i] = dr * g;
    }
  }
}

// ---- Convolution reverb ------------------------------------------------------------------------------

/// In-place radix-2 FFT of (re, im), length a power of two; [inverse] for the inverse (scaled by 1/n).
void fft(Float64List re, Float64List im, {bool inverse = false}) {
  final n = re.length;
  for (var i = 1, j = 0; i < n; i++) {
    var bit = n >> 1;
    for (; j & bit != 0; bit >>= 1) {
      j ^= bit;
    }
    j ^= bit;
    if (i < j) {
      final tr = re[i], ti = im[i];
      re[i] = re[j];
      im[i] = im[j];
      re[j] = tr;
      im[j] = ti;
    }
  }
  for (var len = 2; len <= n; len <<= 1) {
    final ang = 2 * math.pi / len * (inverse ? 1 : -1);
    final wr = math.cos(ang), wi = math.sin(ang);
    for (var i = 0; i < n; i += len) {
      var cr = 1.0, ci = 0.0;
      for (var j = 0; j < len >> 1; j++) {
        final ar = re[i + j], ai = im[i + j];
        final br = re[i + j + (len >> 1)], bi = im[i + j + (len >> 1)];
        final xr = br * cr - bi * ci, xi = br * ci + bi * cr;
        re[i + j] = ar + xr;
        im[i + j] = ai + xi;
        re[i + j + (len >> 1)] = ar - xr;
        im[i + j + (len >> 1)] = ai - xi;
        final ncr = cr * wr - ci * wi;
        ci = cr * wi + ci * wr;
        cr = ncr;
      }
    }
  }
  if (inverse) {
    for (var i = 0; i < n; i++) {
      re[i] /= n;
      im[i] /= n;
    }
  }
}

/// A ConvolverNode with a mono input and one impulse response per output channel, normalized the
/// way Chromium does it (by the response's RMS, then −58 dB, then by sample rate). Uniformly
/// partitioned FFT convolution, stateful so a stream can run through it in blocks of any size.
class Convolver {
  Convolver(List<Float32List> ir, this.sr, {this.block = 512}) {
    var power = 0.0;
    var len = 0;
    for (final c in ir) {
      for (final v in c) {
        power += v * v;
      }
      len = math.max(len, c.length);
    }
    var rmsPower = math.sqrt(power / (ir.length * len));
    if (!rmsPower.isFinite || rmsPower < 0.000125) rmsPower = 0.000125;
    final scale = 1 / rmsPower * math.pow(10, -58 / 20) * 44100 / sr;
    _parts = (len / block).ceil();
    final n = block * 2;
    for (final c in ir) {
      final parts = <(Float64List, Float64List)>[];
      for (var p = 0; p < _parts; p++) {
        final re = Float64List(n), im = Float64List(n);
        for (var i = 0; i < block; i++) {
          final j = p * block + i;
          if (j < c.length) re[i] = c[j] * scale;
        }
        fft(re, im);
        parts.add((re, im));
      }
      _ir.add(parts);
    }
    for (var p = 0; p < _parts; p++) {
      _history.add((Float64List(n), Float64List(n)));
    }
    _tails = [for (final _ in ir) Float64List(block)];
    _out = [for (final _ in ir) Float64List(block)];
  }

  final int sr;
  final int block;
  late final int _parts;
  final List<List<(Float64List, Float64List)>> _ir = [];

  /// The spectra of the last `_parts` input blocks, newest at `_head`.
  final List<(Float64List, Float64List)> _history = [];
  int _head = 0;
  late final List<Float64List> _tails;
  late final List<Float64List> _out;
  int _fill = 0;
  late final Float64List _pending = Float64List(block);

  int get channels => _ir.length;

  /// Convolves [input] (mono), returning one buffer per channel, the same length. The output lags the
  /// input by one block (block/sr seconds): Chromium's convolver has a little latency too.
  List<Float32List> process(Float32List input) {
    final outs = [for (var c = 0; c < channels; c++) Float32List(input.length)];
    for (var i = 0; i < input.length; i++) {
      for (var c = 0; c < channels; c++) {
        outs[c][i] = _out[c][_fill];
      }
      _pending[_fill] = input[i];
      if (++_fill == block) {
        _fill = 0;
        _runBlock();
      }
    }
    return outs;
  }

  void _runBlock() {
    final n = block * 2;
    _head = (_head - 1 + _parts) % _parts;
    final (hr, hi) = _history[_head];
    hr.fillRange(0, n, 0);
    hi.fillRange(0, n, 0);
    for (var i = 0; i < block; i++) {
      hr[i] = _pending[i];
    }
    fft(hr, hi);
    final accR = Float64List(n), accI = Float64List(n);
    for (var c = 0; c < channels; c++) {
      accR.fillRange(0, n, 0);
      accI.fillRange(0, n, 0);
      for (var p = 0; p < _parts; p++) {
        final (xr, xi) = _history[(_head + p) % _parts];
        final (fr, fi) = _ir[c][p];
        for (var k = 0; k < n; k++) {
          accR[k] += xr[k] * fr[k] - xi[k] * fi[k];
          accI[k] += xr[k] * fi[k] + xi[k] * fr[k];
        }
      }
      fft(accR, accI, inverse: true);
      final out = _out[c], tail = _tails[c];
      for (var i = 0; i < block; i++) {
        out[i] = accR[i] + tail[i];
        tail[i] = accR[i + block];
      }
    }
  }
}

// ---- Measuring ---------------------------------------------------------------------------------------

/// The RMS of [d] (or of d[from, to)).
double rmsOf(Float32List d, [int from = 0, int? to]) {
  final end = to ?? d.length;
  if (end <= from) return 0;
  var s = 0.0;
  for (var i = from; i < end; i++) {
    s += d[i] * d[i];
  }
  return math.sqrt(s / (end - from));
}

double peakOf(Float32List d) {
  var m = 0.0;
  for (final v in d) {
    if (v.abs() > m) m = v.abs();
  }
  return m;
}

/// The power spectrum's centre of mass (Hz), averaged over 2048-sample frames with a Hann window.
double spectralCentroid(Float32List d, int sr) {
  const n = 2048;
  final re = Float64List(n), im = Float64List(n);
  final power = Float64List(n ~/ 2);
  for (var at = 0; at + n <= d.length; at += n ~/ 2) {
    for (var i = 0; i < n; i++) {
      final w = 0.5 - 0.5 * math.cos(2 * math.pi * i / (n - 1));
      re[i] = d[at + i] * w;
      im[i] = 0;
    }
    fft(re, im);
    for (var k = 0; k < n ~/ 2; k++) {
      power[k] += re[k] * re[k] + im[k] * im[k];
    }
  }
  var num = 0.0, den = 0.0;
  for (var k = 0; k < n ~/ 2; k++) {
    num += power[k] * k * sr / n;
    den += power[k];
  }
  return den == 0 ? 0 : num / den;
}

/// [mono] as a 32-bit float WAV file in memory, for SoLoud's loadMem.
Uint8List wav(Float32List mono, int sr) => wavChannels([mono], sr);

/// One Float32List per channel as a 32-bit float WAV file in memory (no clipping, no dither).
Uint8List wavChannels(List<Float32List> channels, int sr) {
  final ch = channels.length;
  final n = channels.first.length;
  final data = n * ch * 4;
  final b = ByteData(44 + data);
  void str(int at, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(at + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 3, Endian.little); // IEEE float
  b.setUint16(22, ch, Endian.little);
  b.setUint32(24, sr, Endian.little);
  b.setUint32(28, sr * ch * 4, Endian.little);
  b.setUint16(32, ch * 4, Endian.little);
  b.setUint16(34, 32, Endian.little);
  str(36, 'data');
  b.setUint32(40, data, Endian.little);
  var at = 44;
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < ch; c++) {
      b.setFloat32(at, channels[c][i], Endian.little);
      at += 4;
    }
  }
  return b.buffer.asUint8List();
}

/// Interleaves channels into little-endian f32 bytes, for SoLoud's buffer streams.
Uint8List interleaved(List<Float32List> channels) {
  final ch = channels.length;
  final n = channels.first.length;
  final out = Float32List(n * ch);
  for (var i = 0; i < n; i++) {
    for (var c = 0; c < ch; c++) {
      out[i * ch + c] = channels[c][i];
    }
  }
  return out.buffer.asUint8List();
}
