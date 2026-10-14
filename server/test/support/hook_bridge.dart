// Shared by the hook helper tests: a stand-in for the office's hook bridge, and the helper run in-process.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/hook.dart';
import 'package:test/test.dart';

/// A local stand-in for the office's hook bridge, recording what arrives.
class Bridge {
  Bridge._(this.server);

  final HttpServer server;
  final requests = <({String url, String? authorization, String? contentType, String body})>[];

  static Future<Bridge> start({int port = 0}) async {
    final bridge = Bridge._(await HttpServer.bind('127.0.0.1', port));
    bridge.server.listen((req) async {
      final body = await utf8.decoder.bind(req).join();
      bridge.requests.add((
        url: req.uri.toString(),
        authorization: req.headers.value('authorization'),
        contentType: req.headers.value('content-type'),
        body: body,
      ));
      req.response.statusCode = 200;
      await req.response.close();
    });
    return bridge;
  }

  String get url => 'http://127.0.0.1:${server.port}';

  Future<void> close() => server.close(force: true);
}

/// Runs the hook helper in-process with [stdin] as its input; returns what it printed.
Future<String> hook(List<String> args, String stdin, Map<String, String> env) async {
  final out = StringBuffer();
  final controller = StreamController<List<int>>();
  final done = controller.stream.listen((b) => out.write(utf8.decode(b))).asFuture<void>();
  final sink = IOSink(controller);
  expect(await runHook(args, input: Stream.value(utf8.encode(stdin)), environment: env, output: sink), 0);
  await sink.close();
  await done;
  return out.toString();
}
