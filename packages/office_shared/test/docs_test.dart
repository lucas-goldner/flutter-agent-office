// The shared half of tests/docs.test.ts (the shelf itself, server/docs.ts, is the server's).
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('links in a doc resolve to paths in the project, and nowhere else', () {
    expect(resolveDocLink('docs/a.md', '../README.md#setup'), (path: 'README.md', hash: 'setup'));
    expect(resolveDocLink('docs/a.md', './b.md'), (path: 'docs/b.md', hash: ''));
    expect(resolveDocLink('docs/a.md', '#usage'), (path: 'docs/a.md', hash: 'usage'));
    expect(resolveDocLink('docs/a.md', '/src/x%20y.ts?plain=1'), (path: 'src/x y.ts', hash: ''));
    for (final href in [
      'https://example.com/a.md',
      '//cdn/x.png',
      'mailto:a@b.c',
      '../../etc/passwd',
      '..',
      '%E0%A4%A',
    ]) {
      expect(resolveDocLink('docs/a.md', href), isNull, reason: href);
    }
    expect(isDocPath('a/b.MD') && isDocPath('x.markdown'), isTrue);
    expect(!isDocPath('a.mdx') && !isDocPath('../a.md') && !isDocPath('a/./b.md') && !isDocPath('md'), isTrue);
  });

  test('the docs API shapes round-trip', () {
    final list = {
      'files': [
        {'path': 'README.md', 'title': 'Agent Office', 'size': 1200, 'mtime': 1700000000000},
        {'path': 'docs/setup.md', 'size': 30, 'mtime': 1700000000001},
      ],
      'more': false,
    };
    expect(DocList.fromJson(list).toJson(), list);
    expect(DocText.fromJson({'path': 'a.md', 'text': '# A'}).toJson(), {'path': 'a.md', 'text': '# A'});
  });
}
