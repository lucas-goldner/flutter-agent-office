import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'reported_usage.dart';

const _tailBytes = 4 * 1024 * 1024;
const _headerBytes = 1024 * 1024;
const _maxSafeInteger = 9007199254740991;

/// Keep the provider total; split cache reads and reasoning from their parent counters.
Usage? codexTokenUsage(Object? value) {
  if (value is! Map) return null;
  final input = value['input_tokens'];
  final output = value['output_tokens'];
  final cache = value['cached_input_tokens'];
  final reasoning = value['reasoning_output_tokens'];
  final total = value['total_tokens'];
  final cacheWrite = value['cache_write_input_tokens'] ?? 0;
  if (![input, output, cache, reasoning, total, cacheWrite].every(isCount)) return null;
  final i = (input as num).toInt(), o = (output as num).toInt(), c = (cache as num).toInt();
  final r = (reasoning as num).toInt(), cw = (cacheWrite as num).toInt(), t = (total as num).toInt();
  if (c > i || r > o || i + o > _maxSafeInteger) return null;
  // Codex can emit synthetic context-window-only snapshots on error. Keep their reported
  // total, but make the incomplete breakdown explicit instead of treating it as billed usage.
  return Usage(
    input: i - c,
    output: o - r,
    reasoning: r,
    cacheRead: c,
    cacheWrite: cw,
    totalTokens: t,
    cost: 0,
    costKnown: false,
    calls: 0,
    callsKnown: false,
    incomplete: t != i + o ? true : null,
  );
}

final _sessionIdPattern = RegExp(r'^[a-zA-Z0-9-]{1,160}$');

/// Read only the explicitly hooked root rollout, never enumerate other conversations. Bounds both
/// memory and I/O; cumulative counters let a tail read recover totals without replaying messages.
/// Rollout formats are not a stable API: unknown records fail closed instead of inventing usage.
class CodexUsageReader {
  String _stamp = '';

  Usage? read(String file, String sessionId, String home) {
    RandomAccessFile? raf;
    try {
      if (!p.isAbsolute(file) || !_sessionIdPattern.hasMatch(sessionId)) return null;
      final root = Directory(home).resolveSymbolicLinksSync();
      final target = File(file).resolveSymbolicLinksSync();
      final relative = p.split(p.relative(target, from: root));
      if (!['sessions', 'archived_sessions'].contains(relative.first) || relative.contains('..')) return null;
      if (!p.basename(target).endsWith('-$sessionId.jsonl')) return null;
      final stat = FileStat.statSync(target);
      if (stat.type != FileSystemEntityType.file) return null;
      raf = File(target).openSync();
      final size = raf.lengthSync();
      // dart:io has no inode; the mtime to the microsecond stands in for it.
      final stamp = '$target:$sessionId:$size:${stat.modified.microsecondsSinceEpoch}';
      if (stamp == _stamp) return null;
      raf.setPositionSync(0);
      final head = raf.readSync(math.min(size, _headerBytes));
      final firstNewline = head.indexOf(10);
      if (firstNewline < 0) return null;
      final meta = jsonDecode(utf8.decode(head.sublist(0, firstNewline), allowMalformed: true));
      if (meta is! Map || meta['type'] != 'session_meta') return null;
      final payload = meta['payload'];
      if (payload is! Map || payload['id'] != sessionId) return null;
      final start = math.max(0, size - _tailBytes);
      raf.setPositionSync(start);
      final tail = raf.readSync(size - start);
      final lines = utf8.decode(tail, allowMalformed: true).split('\n');
      lines.removeLast(); // A final partial line is retried after the next append.
      if (start > 0 && lines.isNotEmpty) lines.removeAt(0);
      for (var i = lines.length - 1; i >= 0; i--) {
        if (!lines[i].contains('"token_count"')) continue;
        Object? row;
        try {
          row = jsonDecode(lines[i]);
        } catch (_) {
          continue;
        }
        if (row is! Map || row['type'] != 'event_msg') continue;
        final rowPayload = row['payload'];
        if (rowPayload is! Map || rowPayload['type'] != 'token_count') continue;
        final info = rowPayload['info'];
        final usage = codexTokenUsage(info is Map ? info['total_token_usage'] : null);
        if (usage == null) continue;
        _stamp = stamp;
        return usage;
      }
    } catch (_) {
      // No data is preferable to exposing malformed, mismatched, or inaccessible files.
    } finally {
      raf?.closeSync();
    }
    return null;
  }
}
