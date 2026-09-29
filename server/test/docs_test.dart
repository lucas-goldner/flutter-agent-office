import 'dart:io';

import 'package:agent_office_server/src/decor.dart' show ImageData, ImageError;
import 'package:agent_office_server/src/docs.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A folder with some Markdown in it, and whatever `git` makes of it.
({String root, String dir, Docs docs}) fixture({required bool git}) {
  final root = Directory.systemTemp.createTempSync('office-docs-').path;
  addTearDown(() => Directory(root).deleteSync(recursive: true));
  final dir = p.join(root, 'proj');
  void put(String file, String text) {
    final f = File(p.join(dir, file));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  put('README.md', '# Agent Office\n\nHello.\n');
  put('docs/setup.markdown', '---\ntitle: "Getting set up"\n---\n\n# Not this one\n');
  put('docs/API.MD', 'Some intro\n\nThe API\n=======\n');
  put('src/index.ts', 'export {};\n');
  put('node_modules/dep/README.md', '# a dependency\n');
  put('.agent-office/meetings/notes.md', '# office notes\n');
  put('ignored/secret.md', '# ignored\n');
  put('pic.png', 'not really a png');
  File(p.join(root, 'outside.md')).writeAsStringSync('# outside\n');
  if (git) {
    void g(List<String> args) => Process.runSync('git', args, workingDirectory: dir);
    g(['init', '-q', '-b', 'main']);
    put('.gitignore', 'node_modules\nignored\n.agent-office/\n');
    g(['add', 'README.md', 'docs', 'src', '.gitignore']);
    g(['-c', 'user.email=t@t', '-c', 'user.name=t', 'commit', '-qm', 'init']);
    // New and not ignored: still the project's.
    put('NOTES.md', 'no heading here\n');
  }
  return (root: root, dir: dir, docs: Docs(dir));
}

void main() {
  test('the shelf is every Markdown file git counts as the project, with its title', () async {
    final (:root, :dir, :docs) = fixture(git: true);
    final list = await docs.list();
    expect(list.more, isFalse);
    expect(list.files.map((f) => [f.path, f.title]), [
      ['docs/API.MD', 'The API'],
      ['docs/setup.markdown', 'Getting set up'],
      ['NOTES.md', null],
      ['README.md', 'Agent Office'],
    ]);
    expect(list.files.every((f) => f.size > 0 && f.mtime > 0), isTrue);
  });

  test('without git, the shelf walks the folder, skipping hidden and dependency folders', () async {
    final (:root, :dir, :docs) = fixture(git: false);
    final list = await docs.list();
    expect(
      list.files.map((f) => f.path).toList()..sort(),
      ['docs/API.MD', 'docs/setup.markdown', 'ignored/secret.md', 'README.md']..sort(),
    );
  });

  test('only Markdown inside the project can be read, not through .. or a link out of it', () async {
    final (:root, :dir, :docs) = fixture(git: true);
    final ok = await docs.read('docs/setup.markdown');
    expect(ok, isA<DocFound>());
    expect((ok as DocFound).doc.text, contains('Getting set up'));
    for (final bad in ['src/index.ts', '../outside.md', p.join(root, 'outside.md'), 'missing.md', 'docs']) {
      expect(await docs.read(bad), isA<DocFailed>(), reason: bad);
    }
    Link(p.join(dir, 'up')).createSync(root);
    final r = await docs.read('up/outside.md');
    expect(r, isA<DocFailed>());
    expect((r as DocFailed).status, 404);
    // Pictures the docs show: only pictures, only from the project.
    final pic = await docs.picture('pic.png');
    expect(pic, isA<ImageData>());
    expect((pic as ImageData).type, 'image/png');
    expect(await docs.picture('README.md'), isA<ImageError>());
    expect(await docs.picture('up/outside.md'), isA<ImageError>());
  });

  test('a doc is titled by its front matter, else its first heading, whatever the style', () {
    expect(docTitle('# Hello *world*\n'), 'Hello world');
    expect(docTitle('<p align="center"><img src="x.png"></p>\n<h1 align="center">Office</h1>\n'), 'Office');
    expect(docTitle('```\n# not a heading\n```\n## Real one ##\n'), 'Real one');
    expect(docTitle('Setext\n---\n'), 'Setext');
    expect(docTitle('- a list item\n---\n'), isNull);
    expect(docTitle('## [Linked](http://x) `code`\n'), 'Linked code');
    expect(docTitle('just words\n'), isNull);
  });

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
}
