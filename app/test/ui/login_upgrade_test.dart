// A one-time sign-in link from the office's terminal (#145), and what the upgrade window promises
// now that workers keep working through a restart (#140).

import 'package:agent_office/pages/login_page.dart' show linkKey;
import 'package:agent_office/ui/upgrade.dart' show upgradeNote;
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the key in a sign-in link', () {
    expect(linkKey('#key=abc123'), 'abc123');
    expect(linkKey('key=abc&x=1'), 'abc');
    expect(linkKey('#key='), isNull);
    expect(linkKey(''), isNull);
    expect(linkKey('#token'), isNull);
  });

  test('the upgrade note', () {
    expect(
      upgradeNote(awake: true),
      endsWith('Workers keep working through the restart, and whatever they were in the middle of carries on.'),
    );
    expect(upgradeNote(awake: false), endsWith('automatically. '));
  });
}
