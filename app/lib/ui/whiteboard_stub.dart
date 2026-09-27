// The whiteboard off the web: Excalidraw is JavaScript, and the desktop app has no web view for it
// yet (stage 2). Same API as whiteboard_web.dart's, doing nothing but saying so.

import 'package:office_shared/protocol.dart';

import '../interop/browser.dart' show notInDesktopApp;
import '../office_scope.dart';
import '../world/office/whiteboard.dart' show WhiteboardStand;
import 'modal.dart';

class WhiteboardHub {
  WhiteboardHub(this.scope, this.stand);

  final OfficeScope scope;
  final WhiteboardStand stand;

  bool get isOpen => false;

  void open() => toast(notInDesktopApp('The whiteboard'));

  void route(ServerMsg msg) {}

  void dispose() {}
}
