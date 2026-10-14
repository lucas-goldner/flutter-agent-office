// The terminal's editing keys (tests/termkeys.test.ts), Ctrl+[ / Ctrl+] by the key's place, and the Esc tip.

import 'package:agent_office/ui/terminal_logic.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Shift+Enter types a new line (Ctrl+J) instead of sending the prompt', () {
    for (final mac in [true, false]) {
      expect(naturalKey('Enter', shift: true, mac: mac), '\n');
      expect(naturalKey('Enter', mac: mac), isNull, reason: 'plain Enter still sends');
      expect(naturalKey('Enter', alt: true, mac: mac), isNull, reason: 'Option+Enter keeps its Esc Enter');
      expect(naturalKey('Enter', shift: true, ctrl: true, mac: mac), isNull);
    }
  });

  test('Ctrl+Backspace deletes a word everywhere; ⌘⌫ deletes the line on a Mac', () {
    expect(naturalKey('Backspace', ctrl: true, mac: true), '\x17');
    expect(naturalKey('Backspace', ctrl: true, mac: false), '\x17');
    expect(naturalKey('Backspace', meta: true, mac: true), '\x15');
    expect(naturalKey('Backspace', meta: true, mac: false), isNull, reason: 'the Windows key is not ⌘');
    expect(naturalKey('Backspace', mac: true), isNull);
    expect(naturalKey('Backspace', alt: true, mac: true), isNull, reason: '⌥⌫ already deletes a word as Esc ⌫');
  });

  test('⌘⌦ and ⌘← / ⌘→ edit and move by line on a Mac only', () {
    expect(naturalKey('Delete', meta: true, mac: true), '\x0b');
    expect(naturalKey('ArrowLeft', meta: true, mac: true), '\x01');
    expect(naturalKey('ArrowRight', meta: true, mac: true), '\x05');
    for (final k in ['Delete', 'ArrowLeft', 'ArrowRight']) {
      expect(naturalKey(k, meta: true, mac: false), isNull);
      expect(naturalKey(k, meta: true, shift: true, mac: true), isNull);
      expect(naturalKey(k, mac: true), isNull);
    }
  });

  test('ordinary keys are left to the terminal', () {
    for (final k in ['a', 'Tab', 'Escape', 'ArrowUp', 'Home']) {
      expect(naturalKey(k, mac: true), isNull);
      expect(naturalKey(k, meta: true, mac: true), isNull);
      expect(naturalKey(k, ctrl: true, mac: false), isNull);
    }
  });

  test('Ctrl+[ and Ctrl+] by the character or the key’s place', () {
    expect(ctrlBracket('[', character: '[', atBracketKey: false), isTrue);
    expect(ctrlBracket('[', character: 'ü', atBracketKey: true), isTrue, reason: 'a German keyboard');
    expect(ctrlBracket(']', character: null, atBracketKey: true), isTrue);
    expect(ctrlBracket(']', character: '+', atBracketKey: true), isFalse, reason: 'Ctrl + + zooms in');
    expect(ctrlBracket('[', character: 'a', atBracketKey: false), isFalse);
  });

  test('the screen asks for Esc, but not just to interrupt', () {
    expect(screenMentionsEsc(['  Skills', '  Esc to close']), isTrue);
    expect(screenMentionsEsc(['Press escape to cancel']), isTrue);
    expect(screenMentionsEsc(['✻ Working… (esc to interrupt)']), isFalse);
    expect(screenMentionsEsc(['escrow', 'desc']), isFalse);
    expect(escLeftTip('Ada'), contains('⎋ Esc at the top or Ctrl+['));
  });
}
