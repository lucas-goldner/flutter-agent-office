import 'package:agent_office/ui/bookshelf_logic.dart';
import 'package:agent_office/ui/markdown.dart' show MarkdownView, headingSlug;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/docs.dart';

DocFile doc(String path, [String? title]) => DocFile(path: path, title: title, size: 100, mtime: 0);

void main() {
  final files = [
    doc('docs/getting-started.md', 'Getting started'),
    doc('README.md', 'Agent Office'),
    doc('CHANGELOG.md'),
    doc('packages/office_shared/README.md'),
    doc('docs/features.md', 'Features'),
  ];

  test('with no filter, the project’s README comes first, then its own docs, then each folder’s', () {
    expect(filterDocs(files, '').map((h) => h.doc.path), [
      'README.md',
      'CHANGELOG.md',
      'docs/features.md',
      'docs/getting-started.md',
      'packages/office_shared/README.md',
    ]);
  });

  test('the letters only need to be in order', () {
    final hits = filterDocs(files, 'gs');
    expect(hits.first.doc.path, 'docs/getting-started.md');
    // The g and the s of getting-started.md, in the path.
    expect(hits.first.path, contains('docs/'.length));
  });

  test('each word narrows it again', () {
    expect(filterDocs(files, 'readme shared').map((h) => h.doc.path), ['packages/office_shared/README.md']);
    expect(filterDocs(files, 'zzz'), isEmpty);
  });

  test('a title counts too', () {
    expect(filterDocs(files, 'agent office').first.doc.path, 'README.md');
  });

  test('letters found together, at the start of a word, rate higher', () {
    expect(
      rateFind(findLetters('fe', 'features.md')!, 'features.md'),
      greaterThan(rateFind(findLetters('fs', 'features.md')!, 'features.md')),
    );
  });

  test('labels', () {
    expect(docSize(512), '512 B');
    expect(docSize(2048), '2.0 KB');
    expect(docSize(20480), '20 KB');
    expect(readTime('word ' * 500), '2 min read');
    expect(githubUrl('git@github.com:acme/office.git'), 'https://github.com/acme/office');
    expect(githubUrl('https://github.com/acme/office'), 'https://github.com/acme/office');
    expect(githubUrl('https://gitlab.com/acme/office'), isNull);
  });

  test('headings get GitHub’s anchors', () {
    expect(headingSlug('Getting Started!'), 'getting-started');
    expect(headingSlug('What’s new in 2.0?'), 'whats-new-in-20');
  });

  testWidgets('a file reads as GitHub shows it: a lone newline is a space, #1 is text, headings get anchors', (
    tester,
  ) async {
    final anchors = <String, ({int level, String text, GlobalKey key})>{};
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MarkdownView('one\ntwo #1\n\n# Head\n\n## Head', file: true, anchors: anchors, selectable: false),
        ),
      ),
    );
    expect(find.textContaining('one two #1'), findsOneWidget);
    expect(anchors.keys, ['head', 'head-1']);
    expect(anchors['head-1']!.level, 2);
  });
}
