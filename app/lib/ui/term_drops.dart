// Files dropped or pasted into a worker's terminal (#171): each goes up to the office (POST
// /api/term/drop), which keeps it on its own machine, and the terminal types where it is, as a terminal
// does with a file dragged into it. Claude Code and Codex turn a picture's path into [Image #1].

import 'package:office_shared/drops.dart';

import '../interop/drops.dart';
import '../net/api.dart';

/// What sends a file's bytes to the office: [Api.postBytes], or a stand-in in tests.
typedef DropPost = Future<ApiResult> Function(String path, List<int> bytes, String contentType);

/// Sends a file dropped or pasted into worker [workerId]'s terminal to the office; where the office keeps
/// it. Throws a [DropError] that says what went wrong.
Future<String> uploadDrop(String? floor, String workerId, DroppedFile f, {DropPost post = Api.postBytes}) async {
  final name = f.name.isNotEmpty ? f.name : 'That file';
  if (f.size > dropMaxBytes) {
    throw DropError('$name is too big to drop into a terminal (${dropMaxBytes ~/ 1024 ~/ 1024} MB at most)');
  }
  final q = Uri(queryParameters: {'floor': floor ?? '', 'worker': workerId, 'name': f.name}).query;
  final ApiResult r;
  try {
    r = await post('/api/term/drop?$q', await f.bytes(), f.type.isNotEmpty ? f.type : 'application/octet-stream');
  } catch (_) {
    throw DropError('$name could not be dropped into the terminal');
  }
  final path = r.body['path'];
  if (!r.ok || path is! String || path.isEmpty) {
    throw DropError(r.error('$name could not be dropped into the terminal'));
  }
  return path;
}

/// Uploads [files] and hands back what the terminal types for them (see [droppedPaths]).
Future<String> uploadDrops(
  String? floor,
  String workerId,
  List<DroppedFile> files, {
  DropPost post = Api.postBytes,
}) async {
  final paths = await Future.wait([for (final f in files) uploadDrop(floor, workerId, f, post: post)]);
  return droppedPaths(paths);
}

class DropError implements Exception {
  const DropError(this.message);
  final String message;

  @override
  String toString() => message;
}
