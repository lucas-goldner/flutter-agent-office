// The controls help (tests/client-help.test.ts).

import 'package:agent_office/ui/help.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every row of the controls help has a key and what it does, and no key is listed twice', () {
    for (final (key, text) in helpRows) {
      expect(key.trim(), isNotEmpty, reason: 'a row with no key: $text');
      expect(text.trim(), isNotEmpty, reason: '$key says nothing');
    }
    final keys = helpRows.map((r) => r.$1).toList();
    expect([
      for (final (i, k) in keys.indexed)
        if (keys.indexOf(k) != i) k,
    ], isEmpty);
  });
}
