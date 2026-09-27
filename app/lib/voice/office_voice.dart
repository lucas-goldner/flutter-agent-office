// Voice and screen sharing in the office: WebRTC in the browser (office_voice_web.dart). The desktop
// app doesn't have it yet (office_voice_stub.dart): the buttons stay dim and say so.

export 'office_voice_stub.dart' if (dart.library.js_interop) 'office_voice_web.dart';
