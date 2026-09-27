// The desktop app against a real office, with the classes the app uses (Api, OfficeSocket): signing
// in keeps the session cookie, whoami works with it, and the WebSocket (dart:io's, with the cookie
// and the office's Origin) is welcomed. Opt-in, since it needs a running office:
//
//   dart run server/bin/agent_office.dart <dir> --port 4720 --password devdevdev
//   AGENT_OFFICE_TEST_SERVER=http://localhost:4720 AGENT_OFFICE_TEST_PASSWORD=devdevdev flutter test test/native_server_test.dart

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/protocol.dart';

import 'package:agent_office/interop/browser.dart';
import 'package:agent_office/net/api.dart';
import 'package:agent_office/net/office_socket.dart';
import 'package:agent_office/net/server.dart';

void main() {
  final server = Platform.environment['AGENT_OFFICE_TEST_SERVER'];
  final password = Platform.environment['AGENT_OFFICE_TEST_PASSWORD'] ?? '';

  test('sign in, whoami, and the socket welcome', () async {
    setServerOrigin(normalizeServer(server!)!);
    expect(await Api.whoami(), isNull, reason: 'no cookie yet');

    final login = await Api.postJson('/api/login', {'name': '', 'password': password});
    expect(login.ok, isTrue, reason: '${login.status} ${login.body}');
    expect(sessionCookie, matches(RegExp(r'^ao_session_\d+=.+')));
    expect(await Api.whoami(), isNotNull);

    final socket = OfficeSocket(
      profile: () => (name: 'Native', color: '#ff8800', look: Look.fromJson(null)),
      floor: () => null,
    );
    final welcome = socket.messages.firstWhere((m) => m is WelcomeMsg).timeout(const Duration(seconds: 10));
    final up = socket.status.first.timeout(const Duration(seconds: 10));
    socket.connect();
    expect(await up, isTrue);
    expect(await welcome, isA<WelcomeMsg>());
    socket.close();

    // Signing out clears the cookie, and the office no longer knows us.
    await Api.postJson('/api/logout', {});
    expect(sessionCookie, isNull);
    expect(await Api.whoami(), isNull);
  }, skip: server == null ? 'set AGENT_OFFICE_TEST_SERVER to run against an office' : false);
}
