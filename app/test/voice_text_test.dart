// The toast when a voice call can't connect (#244).

import 'package:agent_office/voice/voice_text.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('it names who, and says what the office needs', () {
    expect(unreachableText('Ada'), startsWith("🎙️ Can't connect voice with Ada: a network between you blocks"));
    expect(unreachableText(null), contains('with someone:'));
    expect(unreachableText('Ada'), contains('TURN server'));
  });
}
