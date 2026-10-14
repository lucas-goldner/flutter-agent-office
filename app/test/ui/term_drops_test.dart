// Files dropped or pasted into a worker's terminal (#171): what goes up to the office, and what the
// terminal types once it's there.

import 'dart:typed_data';

import 'package:agent_office/interop/drops.dart';
import 'package:agent_office/net/api.dart';
import 'package:agent_office/ui/term_drops.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/drops.dart';

DroppedFile file(String name, {String type = 'image/png', int size = 3}) =>
    DroppedFile(name: name, type: type, size: size, bytes: () async => Uint8List.fromList([1, 2, 3]));

void main() {
  test('each file goes up with its floor, worker, name and type; the paths come back typed for a shell', () async {
    final sent = <(String, List<int>, String)>[];
    Future<ApiResult> post(String path, List<int> bytes, String type) async {
      sent.add((path, bytes, type));
      final name = Uri.parse(path).queryParameters['name']!;
      return ApiResult(200, {'path': '/w/.agent-office/drops/w1/$name'});
    }

    final typed = await uploadDrops('f1', 'w1', [file('Screen Shot.png'), file('notes', type: '')], post: post);
    expect(sent.map((s) => s.$1), [
      '/api/term/drop?floor=f1&worker=w1&name=Screen+Shot.png',
      '/api/term/drop?floor=f1&worker=w1&name=notes',
    ]);
    expect(sent.map((s) => s.$3), ['image/png', 'application/octet-stream']);
    expect(sent.first.$2, [1, 2, 3]);
    expect(typed, r'/w/.agent-office/drops/w1/Screen\ Shot.png /w/.agent-office/drops/w1/notes');
  });

  test('too big, or turned away by the office: it says why', () async {
    Future<ApiResult> refuse(String path, List<int> bytes, String type) async =>
        ApiResult(400, {'error': 'That worker has gone home'});
    await expectLater(
      uploadDrop('f1', 'w1', file('huge.mov', size: dropMaxBytes + 1), post: refuse),
      throwsA(
        isA<DropError>().having(
          (e) => e.message,
          'message',
          'huge.mov is too big to drop into a terminal (25 MB at most)',
        ),
      ),
    );
    await expectLater(
      uploadDrop('f1', 'w1', file('a.png'), post: refuse),
      throwsA(isA<DropError>().having((e) => e.message, 'message', 'That worker has gone home')),
    );
    Future<ApiResult> silent(String path, List<int> bytes, String type) async => ApiResult(500, {});
    await expectLater(
      uploadDrop(null, 'w1', file(''), post: silent),
      throwsA(isA<DropError>().having((e) => e.message, 'message', 'That file could not be dropped into the terminal')),
    );
  });
}
