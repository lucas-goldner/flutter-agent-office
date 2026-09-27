import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/codex_usage.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Map<String, Object?> totals([int input = 120, int output = 30]) => {
  'input_tokens': input,
  'cached_input_tokens': 20,
  'cache_write_input_tokens': 5,
  'output_tokens': output,
  'reasoning_output_tokens': 10,
  'total_tokens': input + output,
};

String event([Map<String, Object?>? value]) => jsonEncode({
  'type': 'event_msg',
  'payload': {
    'type': 'token_count',
    'info': {'total_token_usage': value ?? totals()},
  },
});

String header([String id = 'thread-1']) =>
    '${jsonEncode({
      'type': 'session_meta',
      'payload': {'id': id},
    })}\n';

Map<String, dynamic>? js(Usage? u) => u?.toJson();

({String home, String file}) fixture() {
  final home = Directory.systemTemp.createTempSync('office-codex-metrics-').path;
  final dir = p.join(home, 'sessions', '2026', '09', '26');
  Directory(dir).createSync(recursive: true);
  addTearDown(() => Directory(home).deleteSync(recursive: true));
  return (home: home, file: p.join(dir, 'rollout-2026-09-26-thread-1.jsonl'));
}

void main() {
  test('normalizes overlapping Codex token buckets without inventing cost or API calls', () {
    final usage = codexTokenUsage(totals())!;
    expect(usage.toJson(), {
      'input': 100,
      'output': 20,
      'reasoning': 10,
      'cacheRead': 20,
      'cacheWrite': 5,
      'totalTokens': 150,
      'cost': 0,
      'costKnown': false,
      'calls': 0,
      'callsKnown': false,
    });
    expect(usage.totalTokens, 150);
    expect(codexTokenUsage({...totals(), 'total_tokens': 200000})?.totalTokens, 200000);
    expect(codexTokenUsage({...totals(), 'total_tokens': 200000})?.incomplete, true);
    expect(codexTokenUsage({...totals(), 'cache_write_input_tokens': null})?.cacheWrite, 0);
    for (final bad in <Object?>[
      null,
      {...totals(), 'input_tokens': -1},
      {...totals(), 'cached_input_tokens': 121},
      {...totals(), 'reasoning_output_tokens': 31},
      {...totals(), 'total_tokens': 9007199254740991 + 1},
      {...totals(), 'output_tokens': double.infinity},
    ]) {
      expect(codexTokenUsage(bad), isNull);
    }
  });

  test('replaces cumulative snapshots, ignores replays, and waits for complete appended lines', () {
    final (:home, :file) = fixture();
    final reader = CodexUsageReader();
    final f = File(file);
    f.writeAsStringSync('${header()}${event()}\n${event()}\n');
    expect(js(reader.read(file, 'thread-1', home)), js(codexTokenUsage(totals())));
    expect(reader.read(file, 'thread-1', home), isNull);
    f.writeAsStringSync(event(totals(240, 60)), mode: FileMode.append);
    expect(js(reader.read(file, 'thread-1', home)), js(codexTokenUsage(totals())));
    f.writeAsStringSync('\n', mode: FileMode.append);
    expect(js(reader.read(file, 'thread-1', home)), js(codexTokenUsage(totals(240, 60))));
    f.writeAsStringSync('${header()}${event(totals(140, 40))}\n');
    expect(js(reader.read(file, 'thread-1', home)), js(codexTokenUsage(totals(140, 40))));
  });

  test('rejects foreign session metadata, outside paths and symlink escapes', () {
    final (:home, :file) = fixture();
    final reader = CodexUsageReader();
    File(file).writeAsStringSync('${header('foreign-thread')}${event()}\n');
    expect(reader.read(file, 'thread-1', home), isNull);
    expect(reader.read(file, '../thread-1', home), isNull);
    final outside = p.join(home, 'rollout-other-thread-1.jsonl');
    File(outside).writeAsStringSync('${header()}${event()}\n');
    expect(reader.read(outside, 'thread-1', home), isNull);
    final link = p.join(home, 'sessions', 'rollout-link-thread-1.jsonl');
    Link(link).createSync(outside);
    expect(reader.read(link, 'thread-1', home), isNull);
  });

  test('bounded tail recovers cumulative usage after large non-metric records', () {
    final (:home, :file) = fixture();
    File(file).writeAsStringSync(
      '${header()}${jsonEncode({'type': 'response_item', 'payload': 'x' * (5 * 1024 * 1024)})}\n${event()}\n',
    );
    expect(js(CodexUsageReader().read(file, 'thread-1', home)), js(codexTokenUsage(totals())));
  });
}
