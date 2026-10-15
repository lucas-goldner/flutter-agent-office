import 'dart:io';

import 'package:agent_office_server/src/floor_pull.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String origin, floor, other;
  void git(String dir, List<String> args) {
    final r = Process.runSync('git', ['-c', 'user.email=a@b', '-c', 'user.name=a', ...args], workingDirectory: dir);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  void commit(String dir, String file, String text) {
    File('$dir/$file').writeAsStringSync(text);
    git(dir, ['add', file]);
    git(dir, ['commit', '-qm', file]);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('pull-');
    origin = '${root.path}/origin.git';
    floor = '${root.path}/floor';
    other = '${root.path}/other';
    git(root.path, ['init', '-q', '--bare', '-b', 'main', origin]);
    git(root.path, ['clone', '-q', origin, floor]);
    commit(floor, 'a.txt', 'a');
    git(floor, ['push', '-q', 'origin', 'main']);
    git(root.path, ['clone', '-q', origin, other]);
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('already up to date, then the new commits come in', () async {
    expect(await pullLatest(floor), (branch: 'main', commits: 0, error: null));
    commit(other, 'b.txt', 'b');
    commit(other, 'c.txt', 'c');
    git(other, ['push', '-q', 'origin', 'main']);
    expect(await pullLatest(floor), (branch: 'main', commits: 2, error: null));
    expect(File('$floor/c.txt').existsSync(), isTrue);
  });

  test('changes of its own the pull would overwrite are left alone', () async {
    commit(other, 'a.txt', 'theirs');
    git(other, ['push', '-q', 'origin', 'main']);
    File('$floor/a.txt').writeAsStringSync('mine, not committed');
    final r = await pullLatest(floor);
    expect(r.error, contains('changes of its own'));
    expect(File('$floor/a.txt').readAsStringSync(), 'mine, not committed');
  });

  test('a branch that went another way is not merged', () async {
    commit(other, 'b.txt', 'b');
    git(other, ['push', '-q', 'origin', 'main']);
    commit(floor, 'local.txt', 'local');
    final r = await pullLatest(floor);
    expect(r.error, contains('commits of its own'));
    expect(File('$floor/b.txt').existsSync(), isFalse);
  });

  test('a branch with nothing on GitHub says so', () async {
    git(floor, ['checkout', '-q', '-b', 'only-here']);
    expect((await pullLatest(floor)).error, contains('no branch on GitHub'));
  });

  test('a base branch the checkout is not on is brought up to date without switching', () async {
    git(other, ['checkout', '-q', '-b', 'develop']);
    commit(other, 'd.txt', 'd');
    git(other, ['push', '-q', 'origin', 'develop']);
    // Not here yet: made, tracking GitHub's.
    expect(await pullLatest(floor, base: 'develop'), (branch: 'develop', commits: 0, error: null));
    commit(other, 'e.txt', 'e');
    commit(other, 'f.txt', 'f');
    git(other, ['push', '-q', 'origin', 'develop']);
    expect(await pullLatest(floor, base: 'develop'), (branch: 'develop', commits: 2, error: null));
    final head = Process.runSync('git', ['rev-parse', '--abbrev-ref', 'HEAD'], workingDirectory: floor);
    expect('${head.stdout}'.trim(), 'main', reason: 'the checkout stays where it was');
    expect((await pullLatest(floor, base: 'nope')).error, contains('no nope on GitHub'));
  });
}
