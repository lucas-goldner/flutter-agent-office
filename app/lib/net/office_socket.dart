// The office's WebSocket: one JSON object a frame, both ways (a port of net.ts).

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import '../interop/browser.dart';
import '../net/api.dart';
import '../shared/avatar.dart';
import '../shared/protocol.dart';

typedef Profile = ({String name, String color, Look look});

class OfficeSocket {
  OfficeSocket({required this.profile, required this.floor});

  /// Who you are, read on every (re)connect.
  final Profile Function() profile;

  /// The floor to come back to after a reload or a restart.
  final String? Function() floor;

  web.WebSocket? _ws;
  int _retry = 0;
  bool _closedByUs = false;

  /// The server is restarting on purpose: retry every second instead of backing off.
  bool _restartExpected = false;
  bool up = false;

  final _messages = StreamController<ServerMsg>.broadcast(sync: true);
  final _status = StreamController<bool>.broadcast(sync: true);

  Stream<ServerMsg> get messages => _messages.stream;
  Stream<bool> get status => _status.stream;

  void connect() {
    final p = profile();
    final q = <String, String>{
      'name': p.name,
      'color': p.color,
      'skin': '${p.look.skin}',
      'hair': '${p.look.hair}',
      'style': '${p.look.style}',
    };
    final f = floor();
    if (f != null) q['floor'] = f;
    final proto = isSecure ? 'wss' : 'ws';
    final ws = web.WebSocket('$proto://$locationHost/ws?${Uri(queryParameters: q).query}');
    _ws = ws;
    ws.onopen = ((web.Event _) {
      _retry = 0;
      up = true;
      _status.add(true);
    }).toJS;
    ws.onmessage = ((web.MessageEvent ev) {
      final data = ev.data;
      if (!data.isA<JSString>()) return;
      Object? json;
      try {
        json = jsonDecode((data as JSString).toDart);
      } catch (_) {
        return;
      }
      if (json is Map<String, dynamic>) _messages.add(ServerMsg.parse(json));
    }).toJS;
    ws.onclose = ((web.CloseEvent _) {
      if (!identical(_ws, ws)) return;
      up = false;
      _status.add(false);
      if (_closedByUs) return;
      _reconnect();
    }).toJS;
  }

  Future<void> _reconnect() async {
    // Session expired? Go back to the door.
    try {
      final me = await Api.whoami();
      if (me == null) return goTo('/login');
    } catch (_) {
      // offline; keep retrying
    }
    final delay = _restartExpected ? 1000 : (500 * (1 << _retry++)).clamp(0, 8000);
    Timer(Duration(milliseconds: delay), connect);
  }

  void expectRestart() => _restartExpected = true;

  void send(ClientMsg msg) {
    final ws = _ws;
    if (ws != null && ws.readyState == web.WebSocket.OPEN) ws.send(jsonEncode(msg.toJson()).toJS);
  }

  void close() {
    _closedByUs = true;
    _ws?.close();
  }
}
