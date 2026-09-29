// Voice and screen sharing in the office (main.ts's "Voice & screen share" section): the buttons
// and keys, the lounge TV showing whoever shares (or its idle card), the thumbnails and the viewer,
// mouths moving with each voice, proximity volume, and who's speaking in the people list.

import 'dart:convert';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart' hide Material;
import 'package:vector_math/vector_math.dart' as vm;
import 'package:web/web.dart' as web;

import '../net/office_socket.dart' hide Profile;
import '../state/store.dart';
import '../ui/hud.dart';
import '../ui/modal.dart';
import '../ui/theme.dart';
import '../world/character.dart';
import '../world/office/loft.dart' show Face;
import '../world/office/parts.dart' show canvasTexture;
import 'share_views.dart';
import 'video_texture.dart';
import 'voice.dart';

class OfficeVoice {
  OfficeVoice({required this.store, required OfficeSocket net, required this.tv, required this.state})
    : voice = Voice(net, store) {
    _tvVideo = web.HTMLVideoElement()
      ..muted = true
      ..playsInline = true
      ..autoplay = true;
    _tvTexture = VideoTexture(_tvVideo);
    tv.material.baseColorFactor = vm.Vector4(1, 1, 1, 1);
    tvIdle().then((t) {
      _idle = t;
      _tvTexture.fallback = t;
      if (_tvStream == null) tv.material.baseColorTexture = t;
    });
    voice.onChange(_onChange);
    store.topic(Topic.peers).addListener(_onPeers);
    _onChange();
    _devHook();
  }

  final Store store;
  final Face tv;
  final Voice voice;

  /// What the HUD's voice buttons show.
  final ValueNotifier<VoiceState> state;

  /// Peer ids talking right now (you too), for the people list.
  final ValueNotifier<Set<String>> speaking = ValueNotifier(const {});

  /// Other people's screens on your floor, for the thumbnails.
  final ValueNotifier<List<Share>> thumbs = ValueNotifier(const []);

  late final web.HTMLVideoElement _tvVideo;
  late final VideoTexture _tvTexture;
  Texture2D? _idle;
  web.MediaStream? _tvStream;
  double _speakTick = 0;

  /// The thumbnails, for the HUD's shares slot.
  late final Widget sharesWidget = ShareThumbs(shares: thumbs, onWatch: watchShare);

  /// window.__voice, as the old client had it: for the dev console and the headless tests.
  void _devHook() {
    final hook = JSObject()
      ..setProperty('join'.toJS, (() => toggleVoice().toJS).toJS)
      ..setProperty('share'.toJS, (() => toggleShare().toJS).toJS)
      ..setProperty(
        'state'.toJS,
        (() => jsonEncode({
          'inVoice': voice.inVoice,
          'sharing': voice.sharing,
          'rtc': voice.connectionStates,
          'shares': [for (final s in currentShares()) s.who],
          'tv': _tvStream != null,
          'speaking': speaking.value.toList(),
          'level': voice.localLevel,
        }).toJS).toJS,
      );
    web.window.setProperty('__voice'.toJS, hook);
  }

  // ---- Buttons and keys -------------------------------------------------------------------------

  /// The Join / Leave voice item in the ☰ menu.
  Future<void> toggleVoice({bool pushToTalk = false}) async {
    if (voice.inVoice) {
      voice.leaveVoice();
    } else {
      await joinVoice(pushToTalk: pushToTalk);
    }
  }

  /// V out of voice: joins it, muted with push to talk.
  Future<void> joinVoice({bool pushToTalk = false}) async {
    final err = await voice.joinVoice(muted: pushToTalk);
    if (err != null) {
      toast(err, ToastKind.warn);
    } else if (pushToTalk && voice.inVoice) {
      toast('🎙️ In voice, muted: hold V to talk');
    }
  }

  /// M, and the 🎙️ button.
  void toggleMute() => voice.toggleMute();

  /// Switching push to talk on mutes you; back to an open mic turns it on.
  void setMuted(bool muted) => voice.setMuted(muted);

  /// V held down in voice, and let go.
  void startTalking() => voice.startTalking();
  void stopTalking() => voice.stopTalking();

  /// The Share screen button.
  Future<void> toggleShare() async {
    if (voice.sharing) {
      voice.stopShare();
    } else {
      final err = await voice.startShare();
      if (err != null) toast(err, ToastKind.warn);
    }
  }

  // ---- Messages ---------------------------------------------------------------------------------

  /// A welcome is on its way in: this page has a new id, so every connection starts over.
  void beforeWelcome() => voice.reset();

  /// After a welcome (a reconnect too): tell the office what you're doing again, and connect.
  void welcomed() {
    if (voice.inVoice || voice.sharing) voice.sendState();
    voice.syncPeers();
  }

  void signal(String from, Object? data) => voice.handleSignal(from, data);

  void _onPeers() {
    voice.syncPeers();
    _refreshShares();
  }

  void _onChange() {
    final next = VoiceState(
      inVoice: voice.inVoice,
      muted: voice.muted,
      sharing: voice.sharing,
      available: Voice.available,
    );
    if (next != state.value) state.value = next;
    _refreshShares();
  }

  // ---- Shares and the TV ------------------------------------------------------------------------

  List<Share> currentShares() {
    final out = <Share>[];
    final local = voice.localScreen;
    if (local != null) out.add((who: 'You', stream: local));
    for (final e in voice.remoteScreens().entries) {
      final peer = store.peers[e.key];
      // A screen shared on another floor is on that floor's TV.
      if (peer != null && !store.onMyFloor(peer)) continue;
      out.add((who: peer?.name ?? 'Someone', stream: e.value));
    }
    return out;
  }

  /// Someone else's screen is up on the TV.
  bool get tvShowing => currentShares().any((s) => s.who != 'You');

  void _refreshShares() {
    final shares = currentShares();
    // Remote shares win the TV; your own share is what others see anyway.
    final pick = shares.where((s) => s.who != 'You').firstOrNull ?? shares.firstOrNull;
    final stream = pick?.stream;
    if (stream != _tvStream) {
      _tvStream = stream;
      _tvVideo.srcObject = stream;
      _tvTexture.restart();
      if (stream != null) _tvVideo.play().toDart.catchError((_) => null);
      tv.material.baseColorTexture = stream != null ? _tvTexture : _idle;
    }
    final others = shares.where((s) => s.who != 'You').toList();
    final was = thumbs.value;
    final same =
        was.length == others.length &&
        [for (var i = 0; i < was.length; i++) was[i].who == others[i].who && was[i].stream.id == others[i].stream.id]
            .every((x) => x);
    if (!same) thumbs.value = others;
  }

  /// E at the TV (or the couch facing it): watch whoever's sharing, or share yourself.
  void watchShare() {
    final shares = currentShares();
    if (shares.isEmpty) {
      toggleShare();
      return;
    }
    // What's on the TV: someone else's screen before your own.
    openViewer(shares.where((s) => s.who != 'You').firstOrNull ?? shares.first);
  }

  /// The TV's hint: a key for its hint-bar cache, and what it says.
  (String, List<HintPart>) tvHint() {
    final any = currentShares().isNotEmpty;
    return ('$any', [const HintTitle('📺 Office TV'), HintKey('E', any ? 'Watch full screen' : 'Share your screen')]);
  }

  // ---- The frame --------------------------------------------------------------------------------

  /// Mouths move with each voice, and you hear people louder the closer they are. [people] are
  /// the others on your floor, by peer id; [at] is where you stand. [now] is in milliseconds.
  void tick(double now, Person me, Map<String, Person> people, vm.Vector3 at) {
    me.setVoiceLevel(voice.inVoice ? voice.localLevel : 0);
    for (final e in people.entries) {
      final p = store.peers[e.key];
      e.value.setVoiceLevel(p != null && p.voice && !p.muted ? voice.levelOf(e.key) : 0);
      final pos = e.value.root.position;
      final d = math.sqrt(math.pow(pos.x - at.x, 2) + math.pow(pos.z - at.z, 2));
      voice.setVolume(e.key, d < 4 ? 1 : math.max(0.2, 1 - (d - 4) / 16));
    }
    if (now - _speakTick <= 200) return;
    _speakTick = now;
    final talking = <String>{
      for (final id in store.peers.keys)
        if (voice.levelOf(id) > kSpeaking) id,
    };
    if (talking.length != speaking.value.length || !talking.containsAll(speaking.value)) speaking.value = talking;
    // People on other floors can't be heard here (their voice connection stays up for when you meet).
    for (final id in voice.connected) {
      if (!people.containsKey(id)) voice.setVolume(id, 0);
    }
  }

  void dispose() {
    store.topic(Topic.peers).removeListener(_onPeers);
    voice.dispose();
    _tvVideo.srcObject = null;
    _tvTexture.dispose();
  }
}

/// The TV when nobody is sharing: a gradient card saying how to put something up.
Future<Texture2D> tvIdle() => canvasTexture(1280, 720, (g) {
  const r = Rect.fromLTWH(0, 0, 1280, 720);
  g.drawRect(
    r,
    Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFF3A0CA3), Color(0xFF4CC9F0)],
      ).createShader(r),
  );
  void text(String s, double size, FontWeight w, double y) {
    final tp = TextPainter(
      text: TextSpan(
        text: s,
        style: TextStyle(
          fontFamily: kFont,
          fontFamilyFallback: kFallback,
          fontSize: size,
          fontWeight: w,
          color: const Color(0xFFFFFFFF),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // Canvas text sits on its baseline at y; lay it out the same way.
    tp.paint(g, Offset(640 - tp.width / 2, y - tp.computeDistanceToActualBaseline(TextBaseline.alphabetic)));
  }

  text('📺 Office TV', 88, FontWeight.w900, 330);
  text('Click “Share screen” to put something up here', 44, FontWeight.w700, 420);
});
