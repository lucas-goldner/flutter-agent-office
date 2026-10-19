// A worker hired from a template is named after it (see Workers.spawn): one line, trimmed, and its
// branch made of what's left.

import 'package:agent_office_server/src/workers.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test("a worker template's name: one line, trimmed, and a branch made of what's left", () {
    expect(workerNameOf('  Log\n Designer 🐚 '), 'Log Designer');
    expect(workerNameOf('x' * 30), hasLength(workerTemplateNameMax));
    expect(branchSlug('Log Designer'), 'log-designer');
    expect(branchSlug('ログ設計'), 'worker');
    expect(branchSlug('QA: 準備 2'), 'qa-2');
  });
}
