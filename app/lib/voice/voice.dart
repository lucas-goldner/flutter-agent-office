// Mesh WebRTC for voice and screen share, straight on the browser's RTCPeerConnection through
// package:web (a port of voice.ts). Signalling rides the office socket as `rtc` messages, and the
// "perfect negotiation" pattern lets either side add or drop tracks at any time.

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

import '../net/office_socket.dart' hide Profile;
import 'package:office_shared/protocol.dart';
import '../state/store.dart';

class _Conn {
  _Conn(this.pc, this.polite, this.audio);
  final web.RTCPeerConnection pc;
  final bool polite;
  final web.HTMLAudioElement audio;
  bool makingOffer = false;
  bool ignoreOffer = false;
  web.MediaStream? audioStream;
  web.MediaStream? screen;
  web.RTCRtpSender? micSender;
  web.RTCRtpSender? screenSender;
  double level = 0;
  web.AnalyserNode? analyser;
}

class Voice {
  Voice(this.net, this.store) {
    // Often enough for mouths to keep up with syllables.
    _levels = Timer.periodic(const Duration(milliseconds: 40), (_) => _sampleLevels());
  }

  final OfficeSocket net;
  final Store store;
  final Map<String, _Conn> _conns = {};
  web.MediaStream? _mic;
  web.MediaStream? _screen;
  web.AudioContext? _audioCtx;
  web.AnalyserNode? _localAnalyser;
  final List<VoidCallback> _listeners = [];
  late final Timer _levels;
  bool muted = false;
  double localLevel = 0;

  /// Asking for the mic, so a second join waits for the first instead of asking again.
  Future<String?>? _joining;

  /// Push to talk is held down: letting go mutes you.
  bool _talking = false;

  /// Voice and screen sharing need a secure context (https or localhost).
  static bool get available => web.window.isSecureContext;

  bool get inVoice => _mic != null;
  bool get sharing => _screen != null;
  web.MediaStream? get localScreen => _screen;

  void onChange(VoidCallback fn) => _listeners.add(fn);

  void _notify() {
    for (final fn in [..._listeners]) {
      fn();
    }
  }

  void _changed() {
    _notify();
    sendState();
  }

  /// Tells the office whether you're in voice, muted, sharing.
  void sendState() => net.send(VoiceCmd(voice: inVoice, muted: muted, sharing: sharing));

  /// Remote screen shares currently being received, keyed by peer id.
  Map<String, web.MediaStream> remoteScreens() {
    final out = <String, web.MediaStream>{};
    for (final e in _conns.entries) {
      final s = e.value.screen;
      if (s == null || store.peers[e.key]?.sharing != true) continue;
      if (s.getVideoTracks().toDart.any((t) => t.readyState == 'live')) out[e.key] = s;
    }
    return out;
  }

  double levelOf(String peerId) => peerId == store.you ? localLevel : (_conns[peerId]?.level ?? 0);

  /// The RTCPeerConnection state towards each peer, for the dev console and tests.
  Map<String, String> get connectionStates => {for (final e in _conns.entries) e.key: e.value.pc.connectionState};

  /// [muted] joins with the mic off, for push to talk.
  Future<String?> joinVoice({bool muted = false}) {
    if (_mic != null) return Future.value(null);
    return _joining ??= _join(muted).whenComplete(() => _joining = null);
  }

  Future<String?> _join(bool startMuted) async {
    if (!available) return 'Voice needs HTTPS (or localhost). Ask whoever runs the office to enable TLS.';
    try {
      final constraints = web.MediaStreamConstraints(
        audio: {'echoCancellation': true, 'noiseSuppression': true, 'autoGainControl': true}.jsify()!,
      );
      _mic = await web.window.navigator.mediaDevices.getUserMedia(constraints).toDart;
    } catch (err) {
      return 'Microphone unavailable: ${_errText(err, 'message')}';
    }
    final mic = _mic!;
    muted = startMuted;
    _talking = false;
    for (final t in mic.getAudioTracks().toDart) {
      t.enabled = !startMuted;
    }
    final ctx = _ensureAudioCtx();
    if (ctx != null) {
      _localAnalyser = ctx.createAnalyser()..fftSize = 1024;
      ctx.createMediaStreamSource(mic).connect(_localAnalyser!);
    }
    final track = mic.getAudioTracks().toDart.first;
    for (final c in _conns.values) {
      c.micSender = c.pc.addTrack(track, mic);
    }
    _changed();
    return null;
  }

  void leaveVoice() {
    final mic = _mic;
    if (mic == null) return;
    for (final c in _conns.values) {
      final s = c.micSender;
      if (s == null) continue;
      try {
        c.pc.removeTrack(s);
      } catch (_) {
        // connection closed
      }
      c.micSender = null;
    }
    for (final t in mic.getTracks().toDart) {
      t.stop();
    }
    _mic = null;
    _localAnalyser = null;
    localLevel = 0;
    _talking = false;
    _changed();
  }

  void toggleMute() => setMuted(!muted);

  void setMuted(bool mute) {
    final mic = _mic;
    if (mic == null) return;
    _talking = false;
    if (mute == muted) return;
    muted = mute;
    for (final t in mic.getAudioTracks().toDart) {
      t.enabled = !mute;
    }
    _changed();
  }

  /// Push to talk: the mic is on while it's held down, and muted once you let go (see [stopTalking]).
  void startTalking() {
    if (_mic == null || _talking) return;
    setMuted(false);
    _talking = true;
  }

  void stopTalking() {
    if (_talking) setMuted(true);
  }

  Future<String?> startShare() async {
    if (_screen != null) return null;
    final devices = web.window.navigator.mediaDevices;
    if (!available || !devices.has('getDisplayMedia')) return 'Screen sharing needs HTTPS (or localhost).';
    try {
      final options = web.DisplayMediaStreamOptions(video: {'frameRate': 15}.jsify()!, audio: false.toJS);
      _screen = await devices.getDisplayMedia(options).toDart;
    } catch (err) {
      return _errText(err, 'name') == 'NotAllowedError' ? null : 'Could not share: ${_errText(err, 'message')}';
    }
    final screen = _screen!;
    final track = screen.getVideoTracks().toDart.first;
    track.contentHint = 'detail';
    track.addEventListener('ended', ((web.Event _) => stopShare()).toJS);
    for (final c in _conns.values) {
      c.screenSender = c.pc.addTrack(track, screen);
    }
    _changed();
    return null;
  }

  void stopShare() {
    final screen = _screen;
    if (screen == null) return;
    for (final c in _conns.values) {
      final s = c.screenSender;
      if (s == null) continue;
      try {
        c.pc.removeTrack(s);
      } catch (_) {
        // closed
      }
      c.screenSender = null;
    }
    for (final t in screen.getTracks().toDart) {
      t.stop();
    }
    _screen = null;
    _changed();
  }

  /// Called whenever the set of peers changes.
  void syncPeers() {
    for (final id in store.peers.keys) {
      if (id != store.you && !_conns.containsKey(id)) _connect(id);
    }
    for (final id in _conns.keys.toList()) {
      if (!store.peers.containsKey(id)) _drop(id);
    }
  }

  void reset() {
    for (final id in _conns.keys.toList()) {
      _drop(id);
    }
  }

  /// Proximity voice: louder when you're close, never fully silent.
  void setVolume(String peerId, double volume) {
    final c = _conns[peerId];
    if (c != null) c.audio.volume = volume.clamp(0, 1).toDouble();
  }

  Iterable<String> get connected => _conns.keys;

  Future<void> handleSignal(String from, Object? data) async {
    if (data is! Map) return;
    final c = _conns[from] ?? _connect(from);
    final pc = c.pc;
    try {
      final d = data['description'];
      if (d is Map) {
        final type = d['type'] as String? ?? '';
        final collision = type == 'offer' && (c.makingOffer || pc.signalingState != 'stable');
        c.ignoreOffer = !c.polite && collision;
        if (c.ignoreOffer) return;
        await pc.setRemoteDescription(web.RTCSessionDescriptionInit(type: type, sdp: d['sdp'] as String? ?? '')).toDart;
        if (type == 'offer') {
          await pc.setLocalDescription().toDart;
          _signal(from, {'description': _desc(pc.localDescription!)});
        }
      } else if (data.containsKey('candidate')) {
        final cand = data['candidate'];
        try {
          if (cand is Map) {
            await pc.addIceCandidate(cand.jsify() as web.RTCIceCandidateInit).toDart;
          } else {
            await pc.addIceCandidate().toDart;
          }
        } catch (err) {
          if (!c.ignoreOffer) rethrow;
        }
      }
    } catch (err) {
      debugPrint('rtc signal failed: $err');
    }
  }

  void _signal(String to, Map<String, Object?> data) => net.send(RtcCmd(to, data));

  static Map<String, Object?> _desc(web.RTCSessionDescription d) => {'type': d.type, 'sdp': d.sdp};

  web.AudioContext? _ensureAudioCtx() {
    try {
      _audioCtx ??= web.AudioContext();
    } catch (_) {
      _audioCtx = null;
    }
    _audioCtx?.resume();
    return _audioCtx;
  }

  _Conn _connect(String id) {
    final config = web.RTCConfiguration(
      iceServers: [for (final s in store.ice) s.toJson()].jsify() as JSArray<web.RTCIceServer>,
    );
    final pc = web.RTCPeerConnection(config);
    final audio = web.HTMLAudioElement()..autoplay = true;
    final c = _Conn(pc, store.you.compareTo(id) < 0, audio);
    _conns[id] = c;

    pc.onnegotiationneeded = ((web.Event _) {
      () async {
        try {
          c.makingOffer = true;
          await pc.setLocalDescription().toDart;
          _signal(id, {'description': _desc(pc.localDescription!)});
        } catch (err) {
          debugPrint('rtc negotiation failed: $err');
        } finally {
          c.makingOffer = false;
        }
      }();
    }).toJS;
    pc.onicecandidate = ((web.RTCPeerConnectionIceEvent e) {
      final cand = e.candidate;
      _signal(id, {'candidate': cand == null ? null : Map<String, Object?>.from(cand.toJSON().dartify() as Map)});
    }).toJS;
    pc.oniceconnectionstatechange = ((web.Event _) {
      if (pc.iceConnectionState == 'failed') pc.restartIce();
    }).toJS;
    pc.onconnectionstatechange = ((web.Event _) {
      debugPrint('rtc ${store.peers[id]?.name ?? id}: ${pc.connectionState}');
    }).toJS;
    pc.ontrack = ((web.RTCTrackEvent e) {
      final track = e.track;
      debugPrint('rtc ${store.peers[id]?.name ?? id}: ${track.kind} track');
      final streams = e.streams.toDart;
      final stream = streams.isNotEmpty ? streams.first : web.MediaStream([track].toJS);
      if (track.kind == 'audio') {
        c.audioStream = stream;
        audio.srcObject = stream;
        audio.play().toDart.catchError((_) {
          // Autoplay blocked until the user interacts; retry on the next click.
          web.window.addEventListener(
            'pointerdown',
            ((web.Event _) {
              audio.play().toDart.catchError((_) => null);
            }).toJS,
            web.AddEventListenerOptions(once: true),
          );
          return null;
        });
        final ctx = _ensureAudioCtx();
        if (ctx != null) {
          try {
            c.analyser = ctx.createAnalyser()..fftSize = 1024;
            ctx.createMediaStreamSource(stream).connect(c.analyser!);
          } catch (_) {
            // the analyser is optional
          }
        }
      } else {
        c.screen = stream;
        track.addEventListener('unmute', ((web.Event _) => _notify()).toJS);
        track.addEventListener('ended', ((web.Event _) => _notify()).toJS);
      }
      _notify();
    }).toJS;

    // Share whatever we're already sending.
    final mic = _mic, screen = _screen;
    if (mic != null) c.micSender = pc.addTrack(mic.getAudioTracks().toDart.first, mic);
    if (screen != null) c.screenSender = pc.addTrack(screen.getVideoTracks().toDart.first, screen);
    return c;
  }

  void _drop(String id) {
    final c = _conns.remove(id);
    if (c == null) return;
    c.pc.close();
    c.audio.srcObject = null;
    _notify();
  }

  final JSUint8Array _buf = JSUint8Array.withLength(1024);

  double _rms(web.AnalyserNode a) {
    a.getByteTimeDomainData(_buf);
    final b = _buf.toDart;
    var s = 0.0;
    for (final v in b) {
      final x = (v - 128) / 128;
      s += x * x;
    }
    return math.sqrt(s / b.length);
  }

  void _sampleLevels() {
    final local = _localAnalyser;
    localLevel = local != null && !muted ? _rms(local) : 0;
    for (final c in _conns.values) {
      final a = c.analyser;
      c.level = a != null ? _rms(a) : 0;
    }
  }

  void dispose() {
    _levels.cancel();
    leaveVoice();
    stopShare();
    reset();
    _listeners.clear();
  }

  /// A property of a thrown DOMException (name, message), or the error's text.
  static String _errText(Object err, String key) {
    try {
      final v = (err as JSObject).getProperty<JSAny?>(key.toJS);
      if (v != null && v.isA<JSString>()) return (v as JSString).toDart;
    } catch (_) {
      // not a JS error
    }
    return key == 'name' ? '' : err.toString();
  }
}
