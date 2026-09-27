import 'package:agent_office/shared/protocol.dart';
import 'package:agent_office/ui/pull_diff.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const diff = '''diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1,4 +1,5 @@ export function main() {
 import x from 'x';
-const a = 1;
+const a = 2;
+const b = 3;
 console.log(a);
\\ No newline at end of file
diff --git a/docs/new.md b/docs/new.md
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/docs/new.md
@@ -0,0 +1,2 @@
+# New
+hello
diff --git a/old.txt b/old.txt
deleted file mode 100644
--- a/old.txt
+++ /dev/null
@@ -1 +0,0 @@
-bye
diff --git a/src/a.ts b/src/b.ts
similarity index 100%
rename from src/a.ts
rename to src/b.ts
diff --git a/img.png b/img.png
index 1..2 100644
Binary files a/img.png and b/img.png differ
diff --git "a/odd name.ts" "b/odd name.ts"
--- "a/odd name.ts"
+++ "b/odd name.ts"
@@ -10,2 +10,2 @@
-x
+y
''';

GhReviewComment rc(int id, String path, int? line, {GhReviewSide side = GhReviewSide.right, int? replyTo}) => GhReviewComment(
      id: id,
      replyTo: replyTo,
      author: 'ana',
      body: 'Looks off',
      createdAt: '2026-09-01T10:00:00Z',
      url: 'https://github.com/o/r/pull/1#discussion_r$id',
      path: path,
      line: line,
      side: side,
    );

void main() {
  group('parseDiff', () {
    final files = parseDiff(diff);

    test('splits files and reads their status', () {
      expect(files.map((f) => f.path), ['src/app.ts', 'docs/new.md', 'old.txt', 'src/b.ts', 'img.png', 'odd name.ts']);
      expect(files.map((f) => f.status), [FileStatus.M, FileStatus.A, FileStatus.D, FileStatus.R, FileStatus.M, FileStatus.M]);
      expect(files[3].oldPath, 'src/a.ts');
      expect(files[3].lines, isEmpty);
      expect(files[4].binary, isTrue);
    });

    test('numbers lines on both sides', () {
      final f = files.first;
      expect(f.additions, 2);
      expect(f.deletions, 1);
      expect(f.lines.map((l) => l.kind), [LineKind.hunk, LineKind.ctx, LineKind.del, LineKind.add, LineKind.add, LineKind.ctx, LineKind.note]);
      expect([f.lines[1].old, f.lines[1].neu], [1, 1]);
      expect([f.lines[2].old, f.lines[2].neu], [2, null]);
      expect([f.lines[3].old, f.lines[3].neu], [null, 2]);
      expect([f.lines[4].old, f.lines[4].neu], [null, 3]);
      expect([f.lines[5].old, f.lines[5].neu], [3, 4]);
      expect(f.lines[6].text, 'No newline at end of file');
      expect(files.last.lines[1].old, 10);
    });

    test('hashes only the changed lines, like the old client', () {
      expect(fnv(''), 'ztntfp');
      expect(fnv('a'), '1r9wi7g');
      expect(fnv('src/x.ts\n+hello\n-bye'), 'uzapfh');
      expect(fnv('ünïcødé 🎉 long string with many chars ' * 20), '8urpbt');
      final moved = parseDiff(diff.replaceFirst('@@ -1,4 +1,5 @@', '@@ -7,4 +7,5 @@'));
      expect(moved.first.hash, files.first.hash);
      final changed = parseDiff(diff.replaceFirst('+const b = 3;', '+const b = 4;'));
      expect(changed.first.hash, isNot(files.first.hash));
    });
  });

  test('Reviewed marks files, notices changes and forgets old PRs', () {
    final backing = <String, String>{};
    final store = KeyValueStore.memory(backing);
    var now = 1000;
    final files = parseDiff(diff);
    final r = Reviewed('https://github.com/o/r/pull/1', store, now: () => now);
    expect(r.mark(files.first), ReviewMark.none);
    r.set(files.first, true);
    expect(r.mark(files.first), ReviewMark.reviewed);
    // A fresh window reads the mark back; a changed file shows as stale.
    final again = Reviewed('https://github.com/o/r/pull/1', store);
    expect(again.mark(files.first), ReviewMark.reviewed);
    final changed = parseDiff(diff.replaceFirst('+const b = 3;', '+const b = 4;'));
    expect(again.mark(changed.first), ReviewMark.stale);
    again.set(files.first, false);
    expect(backing[reviewedKey], '{}');
    for (var i = 0; i < 65; i++) {
      now++;
      Reviewed('pr$i', store, now: () => now).set(files.first, true);
    }
    expect(Reviewed('pr0', store).mark(files.first), ReviewMark.none);
    expect(Reviewed('pr64', store).mark(files.first), ReviewMark.reviewed);
  });

  test('buildTree squashes single-folder chains and orders like the sidebar', () {
    final files = [for (final p in ['src/client/ui/b.ts', 'src/client/ui/a.ts', 'README.md', 'src/server/x.ts', 'Zeta/q.ts']) DiffFile(p)];
    final t = buildTree(files);
    expect(t.dirs.map((d) => d.name), ['src', 'Zeta']);
    expect(t.dirs.first.dirs.map((d) => d.name), ['client/ui', 'server']);
    expect(t.dirs.first.dirs.first.path, 'src/client/ui');
    expect(treeOrder(t).map((f) => f.path), ['src/client/ui/a.ts', 'src/client/ui/b.ts', 'src/server/x.ts', 'Zeta/q.ts', 'README.md']);
  });

  test('looksGenerated', () {
    expect(looksGenerated('package-lock.json'), isTrue);
    expect(looksGenerated('app/pubspec.lock'), isFalse);
    expect(looksGenerated('a/b/yarn.lock'), isTrue);
    expect(looksGenerated('x.min.js'), isTrue);
    expect(looksGenerated('dist/app.js'), isTrue);
    expect(looksGenerated('src/dist.ts'), isFalse);
  });

  test('threadsByLine and repliesOf', () {
    final cs = [rc(1, 'a.ts', 3), rc(2, 'a.ts', 3, replyTo: 1), rc(3, 'a.ts', 5, side: GhReviewSide.left), rc(4, 'a.ts', null), rc(5, 'b.ts', 1)];
    final t = threadsByLine(cs, 'a.ts');
    expect(t.keys.toSet(), {'RIGHT:3', 'LEFT:5'});
    expect(repliesOf(cs)[1]!.single.id, 2);
  });

  testWidgets('FileDiffLines puts threads under their lines', (tester) async {
    final f = parseDiff(diff).first;
    final keys = <String, GlobalKey<FlashRowState>>{};
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: FileDiffLines(file: f, comments: [rc(1, 'src/app.ts', 3), rc(2, 'src/app.ts', 2, side: GhReviewSide.left)], itemUrl: 'https://github.com/o/r/pull/1', rowKeys: keys),
        ),
      ),
    ));
    expect(find.byType(ReviewThread), findsNWidgets(2));
    expect(keys.keys.toSet(), containsAll(['RIGHT:3', 'LEFT:2']));
    expect(find.text('const b = 3;'), findsOneWidget);
    await tester.pumpWidget(MaterialApp(home: FileDiffLines(file: parseDiff(diff)[4], comments: const [], itemUrl: '')));
    expect(find.text('Binary file — not shown.'), findsOneWidget);
  });
}
