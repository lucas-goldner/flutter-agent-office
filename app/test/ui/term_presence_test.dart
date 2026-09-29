import 'package:agent_office/ui/terminal_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/avatar.dart';
import 'package:office_shared/protocol.dart';

PeerInfo peer(String id, String name) => PeerInfo(
  id: id,
  name: name,
  color: '#abcdef',
  look: const Look(skin: 0, hair: 0, style: 0),
  x: 0,
  y: 0,
  z: 0,
  rotY: 0,
  moving: false,
  voice: false,
  muted: false,
  sharing: false,
);

void main() {
  test('who is typing', () {
    expect(typingLine(['Sam']), 'Sam is typing…');
    expect(typingLine(['Sam', 'Ada']), 'Sam and Ada are typing…');
    expect(typingLine(['Sam', 'Ada', 'Bo']), 'Sam and 2 others are typing…');
  });

  test('initials', () {
    expect(initials('Sam'), 'S');
    expect(initials('ada  lovelace'), 'AL');
    expect(initials('Ada Byron Lovelace'), 'AL');
    expect(initials('   '), '?');
    expect(initials('🙂 face'), '🙂F');
  });

  test('one face per person, you first, typing wherever they have it open', () {
    final peers = {
      for (final p in [peer('a1', 'Ada'), peer('a2', 'Ada'), peer('s', 'Sam'), peer('me', 'Me')]) p.id: p,
    };
    final v = viewersOf(['s', 'a1', 'me', 'a2', 'gone'], peers, 'me', {'a2'});
    expect(v.map((x) => (x.name, x.you, x.typing)), [('Me', true, false), ('Sam', false, false), ('Ada', false, true)]);
  });
}
