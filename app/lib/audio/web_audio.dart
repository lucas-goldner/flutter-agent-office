// Small Web Audio helpers shared by sound.dart and music.dart. Only lib/audio uses these.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:web/web.dart' as web;

extension AudioChain on web.AudioNode {
  /// Connects this node to `next` and returns `next`, like TS's `a.connect(b).connect(c)`.
  T to<T extends web.AudioNode>(T next) {
    connect(next);
    return next;
  }
}

web.BiquadFilterNode biquad(web.BaseAudioContext ctx, String type, double freq, double q) {
  final f = ctx.createBiquadFilter();
  f.type = type;
  f.frequency.value = freq;
  f.Q.value = q;
  return f;
}

/// Ramps `param` from 0 through (seconds after t0, value) points.
void envelope(web.AudioParam param, double t0, List<(double, double)> points) {
  param.setValueAtTime(0, t0);
  for (final (dt, v) in points) {
    param.linearRampToValueAtTime(v, t0 + dt);
  }
}

/// An AudioBuffer holding `channels` (one Float32List each).
web.AudioBuffer audioBuffer(web.BaseAudioContext ctx, List<Float32List> channels) {
  final sr = ctx.sampleRate;
  final b = ctx.createBuffer(channels.length, channels.first.length, sr);
  for (var ch = 0; ch < channels.length; ch++) {
    b.copyToChannel(channels[ch].toJS, ch);
  }
  return b;
}

/// Puts a panner at (x, y, z), on browsers with or without the AudioParam positions.
void place(web.PannerNode pn, double x, double y, double z) {
  if ((pn as JSObject).has('positionX')) {
    pn.positionX.value = x;
    pn.positionY.value = y;
    pn.positionZ.value = z;
  } else {
    pn.setPosition(x, y, z);
  }
}

/// Output level (RMS) of what an analyser hears right now.
double analyserRms(web.AnalyserNode a) {
  final js = Float32List(a.fftSize).toJS;
  a.getFloatTimeDomainData(js);
  return rms(js.toDart);
}

/// The RMS of some samples.
double rms(Float32List d) {
  var s = 0.0;
  for (final v in d) {
    s += v * v;
  }
  return d.isEmpty ? 0 : math.sqrt(s / d.length);
}

/// Fires and forgets a promise, swallowing a rejection (like TS's `void p.catch(() => {})`).
void quietly(JSPromise<JSAny?> p) {
  unawaited(p.toDart.then((_) {}, onError: (Object _) {}));
}
