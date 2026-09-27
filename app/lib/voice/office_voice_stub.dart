// Voice and screen sharing off the web: not in the desktop app yet (stage 2, e.g. flutter_webrtc).
// The same API as office_voice_web.dart's; the HUD's buttons stay dim (VoiceState.available is
// false) and pressing them, or E at the TV, says why.

import 'package:flutter/widgets.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../interop/browser.dart' show notInDesktopApp;
import '../net/office_socket.dart' hide Profile;
import '../state/store.dart';
import '../ui/hud.dart';
import '../ui/modal.dart';
import '../world/character.dart';
import '../world/office/loft.dart' show Face;

class OfficeVoice {
  OfficeVoice({required this.store, required OfficeSocket net, required this.tv, required this.state});

  final Store store;
  final Face tv;

  /// What the HUD's voice buttons show: never available here.
  final ValueNotifier<VoiceState> state;

  /// Peer ids talking right now, for the people list: nobody you can hear.
  final ValueNotifier<Set<String>> speaking = ValueNotifier(const {});

  /// The screen-share thumbnails: none.
  final Widget sharesWidget = const SizedBox.shrink();

  static final String _why = notInDesktopApp('Voice chat and screen sharing');

  Future<void> toggleVoice() async => toast(_why);
  void toggleMute() {}
  Future<void> toggleShare() async => toast(_why);

  void beforeWelcome() {}
  void welcomed() {}
  void signal(String from, Object? data) {}

  bool get tvShowing => false;
  void watchShare() => toast(_why);

  (String, List<HintPart>) tvHint() => ('off', [const HintTitle('📺 Office TV'), HintAside(_why)]);

  void tick(double now, Person me, Map<String, Person> people, vm.Vector3 at) {}

  void dispose() {}
}
