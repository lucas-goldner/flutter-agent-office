import 'package:agent_office/interop/open_url.dart';
import 'package:agent_office/ui/markdown.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:markdown/markdown.dart' as md;

const item = 'https://github.com/acme/rocket/pull/12';

String html(String src) => md.renderToHtml(parseMarkdown(src, itemUrl: item));

Future<void> pump(WidgetTester t, String src) =>
    t.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: MarkdownView(src, itemUrl: item)))));

String allText(WidgetTester t) => t.widgetList<RichText>(find.byType(RichText)).map((r) => r.text.toPlainText()).join('\n');

void main() {
  test('links #refs and @mentions, but not in code or emails', () {
    final h = html('See #34 by @octo-cat, `#99` and me@mail.com');
    expect(h, contains('<a href="https://github.com/acme/rocket/issues/34" class="ref">#34</a>'));
    expect(h, contains('<a href="https://github.com/octo-cat" class="mention">@octo-cat</a>'));
    expect(h, isNot(contains('issues/99')));
    expect(h, isNot(contains('github.com/mail')));
  });

  test('absolutize', () {
    expect(absolutize('docs/a.md', itemUrl: item, anchors: true), 'https://github.com/acme/rocket/blob/HEAD/docs/a.md');
    expect(absolutize('./x.png', itemUrl: item, anchors: false), 'https://github.com/acme/rocket/blob/HEAD/x.png');
    expect(absolutize('#top', itemUrl: '$item#x', anchors: true), '$item#top');
    expect(absolutize('/acme', itemUrl: item, anchors: true), 'https://github.com/acme');
    expect(absolutize('https://x.io', itemUrl: item, anchors: true), 'https://x.io');
    expect(imageSrc('https://i.imgur.com/a.png', item), '/api/image?url=https%3A%2F%2Fi.imgur.com%2Fa.png');
    expect(repoUrlOf('https://github.com/acme/rocket/issues/3#c'), 'https://github.com/acme/rocket');
  });

  test('alerts drop their marker', () {
    final nodes = parseMarkdown('> [!WARNING]\n> Mind the gap');
    final q = nodes.single as md.Element;
    expect(q.attributes['alert'], 'warning');
    expect(q.textContent.trim(), 'Mind the gap');
  });

  testWidgets('draws GFM: breaks, lists, tasks, tables, code, alerts', (t) async {
    await pump(t, '''# Title
line one
line two

- [x] done
- [ ] todo

1. first
2. second

| a | b |
|---|---|
| 1 | 2 |

```dart
void main() {}
```

> [!TIP]
> Try it

<!-- hidden --><details><summary>More</summary>

inner

</details>

Hi <b>there</b><br>again''');
    final text = allText(t);
    expect(text, contains('line one\nline two'));
    expect(text, contains('1.'));
    expect(text, contains('void main() {}'));
    expect(text, contains('💡 Tip'));
    expect(text, contains('Try it'));
    expect(text, contains('More'));
    expect(text, isNot(contains('hidden')));
    expect(text, isNot(contains('<b>')));
    expect(text, contains('Hi there\nagain'));
    expect(find.byType(Table), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('empty text, and links open in a new tab', (t) async {
    await pump(t, '  ');
    expect(find.text('No description provided.'), findsOneWidget);
    await pump(t, 'Fixes #7');
    final rich = t.widget<RichText>(find.byType(RichText).first);
    var tapped = false;
    rich.text.visitChildren((s) {
      if (s is TextSpan && s.text == '#7') {
        (s.recognizer as dynamic).onTap();
        tapped = true;
      }
      return true;
    });
    expect(tapped, isTrue);
    expect(openedUrls.last, 'https://github.com/acme/rocket/issues/7');
  });
}
