// Port of tests/palette.test.ts.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

List<String> titles(String q, List<PaletteItem> items) => [for (final m in rankItems(q, items)) m.item.title];

void main() {
  test('"login" finds the worker whose task card is "Fix Login Redirect"', () {
    const workers = <PaletteItem>[
      PaletteEntry(title: 'Ada', detail: 'Write the release notes · Desk 2'),
      PaletteEntry(title: 'Bo', detail: 'Fix Login Redirect · Desk 7'),
      PaletteEntry(title: 'Cy', detail: 'Tidy the CSS · Desk 3'),
    ];
    final found = rankItems('login', workers);
    expect(found[0].item.title, 'Bo');
    expect(found[0].field, PaletteField.detail);
    // The letters it found are "Login" in the card.
    expect(found[0].hits.map((i) => workers[1].detail![i]).join(), 'Login');
    expect(found.length, 1);
  });

  test('the whole text beats its start, which beats a word start, which beats the middle of a word', () {
    final a = matchText('login', 'Login')!.score;
    final b = matchText('login', 'Login page')!.score;
    final c = matchText('login', 'Fix login')!.score;
    final d = matchText('login', 'Relogin')!.score;
    expect(a > b && b > c && c > d, isTrue, reason: '$a > $b > $c > $d');
  });

  test('an exact or prefix match beats a scattered one', () {
    const items = <PaletteItem>[
      PaletteEntry(title: 'Look over git integration'),
      PaletteEntry(title: 'Log in'),
      PaletteEntry(title: 'Login'),
      PaletteEntry(title: 'Login redirect'),
    ];
    expect(titles('login', items), ['Login', 'Login redirect', 'Log in', 'Look over git integration']);
    expect(matchText('lg', 'Log')!.score, lessThan(matchText('lo', 'Log')!.score));
  });

  test('scattered letters match in order, and prefer the starts of words', () {
    expect(matchText('xyz', 'Fix Login Redirect'), isNull);
    expect(matchText('dx', 'Fix Redirect'), isNull, reason: 'out of order');
    final m = matchText('flr', 'Fix Login Redirect')!;
    expect(m.hits, [0, 4, 10]);
    expect(matchText('flr', 'Fix Login Redirect')!.score, greaterThan(matchText('flr', 'aflxxxxxr')!.score));
  });

  test('several words match anywhere in the text, in any order', () {
    final m = matchText('redirect fix', 'Fix Login Redirect')!;
    expect(m.hits, [0, 1, 2, 10, 11, 12, 13, 14, 15, 16, 17]);
    expect(
      m.score,
      lessThan(matchText('fix login', 'Fix Login Redirect')!.score),
      reason: 'the words together beat the words apart',
    );
  });

  test('any case and extra spaces; an empty query lists everything in order', () {
    expect(matchText('  LOGIN ', 'fix login')!.score, greaterThanOrEqualTo(800));
    const items = <PaletteItem>[PaletteEntry(title: 'b'), PaletteEntry(title: 'a'), PaletteEntry(title: 'c')];
    expect(titles('', items), ['b', 'a', 'c']);
  });

  test('a title beats the same match in the detail line or a keyword', () {
    const items = <PaletteItem>[
      PaletteEntry(title: 'Settings', keywords: ['queue it']),
      PaletteEntry(title: 'Issue #4', detail: 'queue it'),
      PaletteEntry(title: 'Queue it'),
    ];
    expect(titles('queue', items), ['Queue it', 'Issue #4', 'Settings']);
    expect(matchItem('qu', const PaletteEntry(title: 'x', keywords: [null, 'queue']))?.field, PaletteField.keyword);
  });

  test('numbers find issues and pull requests, and desks by label', () {
    const items = <PaletteItem>[
      PaletteEntry(title: '#131 Dark mode'),
      PaletteEntry(title: '#31 Fix the build'),
      PaletteEntry(title: 'Eve', detail: 'Desk 7'),
    ];
    expect(titles('31', items)[0], '#31 Fix the build');
    expect(titles('#31', items)[0], '#31 Fix the build');
    expect(titles('desk 7', items), ['Eve']);
  });

  test('ties keep their order, and the list stops at the most it shows', () {
    final items = [for (var i = 0; i < paletteMax + 20; i++) PaletteEntry(title: 'Worker $i')];
    final found = rankItems('worker', items);
    expect(found.length, paletteMax);
    expect(found[0].item.title, 'Worker 0');
    expect(found[1].item.title, 'Worker 1');
  });

  test('Ctrl+K opens the palette, ⌘K on a Mac, and no other combination does', () {
    PaletteKeyPress key({
      String key = 'k',
      String code = 'KeyK',
      bool ctrlKey = false,
      bool altKey = false,
      bool shiftKey = false,
      bool metaKey = false,
    }) => (key: key, code: code, ctrlKey: ctrlKey, altKey: altKey, shiftKey: shiftKey, metaKey: metaKey);
    expect(isPaletteKey(key(ctrlKey: true), false), isTrue);
    expect(isPaletteKey(key(ctrlKey: true, key: 'K'), false), isTrue, reason: 'with caps lock');
    expect(isPaletteKey(key(metaKey: true), false), isFalse);
    expect(isPaletteKey(key(metaKey: true), true), isTrue);
    expect(isPaletteKey(key(ctrlKey: true), true), isFalse, reason: 'Ctrl+K on a Mac is left to the text box');
    expect(isPaletteKey(key(ctrlKey: true, shiftKey: true), false), isFalse);
    expect(isPaletteKey(key(ctrlKey: true, altKey: true), false), isFalse);
    expect(isPaletteKey(key(), false), isFalse, reason: 'plain K walks nowhere');
    expect(isPaletteKey(key(ctrlKey: true, key: 'j', code: 'KeyJ'), false), isFalse);
    // A Russian layout: the K key types л.
    expect(isPaletteKey(key(ctrlKey: true, key: 'л'), false), isTrue);
    // Dvorak: the key in K's place types t, which isn't K.
    expect(isPaletteKey(key(ctrlKey: true, key: 't'), false), isFalse);
  });
}
