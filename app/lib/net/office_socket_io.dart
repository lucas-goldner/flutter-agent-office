// The office's WebSocket in the desktop app (office_socket_web.dart in the browser): dart:io's, which
// sends the session cookie and the office's Origin that a page served by the office would have.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/avatar.dart';
import 'package:office_shared/protocol.dart';

import '../interop/browser.dart';
import 'api.dart';
import 'server.dart';

typedef Profile = ({String name, String color, Look look});

class OfficeSocket {
  OfficeSocket({required this.profile, required this.floor});

  /// Who you are, read on every (re)connect.
  final Profile Function() profile;

  /// The floor to come back to after a reload or a restart.
  final String? Function() floor;

  WebSocket? _ws;

  /// Bumped on every connect, so a connection that's been replaced (or closed by us) stays quiet.
  int _attempt = 0;
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
    final url = '$proto://$locationHost/ws?${Uri(queryParameters: q).query}';
    final attempt = ++_attempt;
    _ws = null;
    WebSocket.connect(url, headers: serverHeaders()).then(
      (ws) {
        if (attempt != _attempt || _closedByUs) {
          ws.close();
          return;
        }
        _ws = ws;
        _retry = 0;
        up = true;
        _status.add(true);
        ws.listen(
          (data) {
            if (data is! String) return;
            Object? json;
            try {
              json = jsonDecode(data);
            } catch (_) {
              return;
            }
            if (json is Map<String, dynamic>) _messages.add(ServerMsg.parse(json));
          },
          onDone: () => _closed(attempt),
          onError: (Object _) {}, // onDone follows
          cancelOnError: false,
        );
      },
      // Refused (signed out, wrong Origin) or unreachable: like the browser's close before open.
      onError: (Object _) => _closed(attempt),
    );
  }

  void _closed(int attempt) {
    if (attempt != _attempt) return;
    _ws = null;
    up = false;
    _status.add(false);
    if (_closedByUs) return;
    _reconnect();
  }

  Future<void> _reconnect() async {
    // Session expired? Go back to the door.
    try {
      final me = await Api.whoami();
      if (me == null) return goTo('/login');
    } catch (_) {
      // offline; keep retrying
    }
    if (_closedByUs) return;
    final delay = _restartExpected ? 1000 : (500 * (1 << _retry++)).clamp(0, 8000);
    Timer(Duration(milliseconds: delay), () {
      if (!_closedByUs) connect();
    });
  }

  void expectRestart() => _restartExpected = true;

  void send(ClientMsg msg) {
    final ws = _ws;
    if (ws != null && ws.readyState == WebSocket.open) ws.add(jsonEncode(msg.toJson()));
  }

  void close() {
    _closedByUs = true;
    _ws?.close();
  }
}
