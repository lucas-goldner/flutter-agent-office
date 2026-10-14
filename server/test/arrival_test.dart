import 'package:agent_office_server/src/server.dart' show spotFrom;
import 'package:test/test.dart';

void main() {
  test('coming back in, the spot on the socket URL is where you stand again', () {
    expect(spotFrom(Uri.parse('/ws?floor=a&x=3.5&y=0&z=-2&rotY=1.25')), (x: 3.5, y: 0.0, z: -2.0, rotY: 1.25));
    // Far away is pulled in, and a missing height or facing is 0.
    expect(spotFrom(Uri.parse('/ws?x=500&z=-500')), (x: 60.0, y: 0.0, z: -60.0, rotY: 0.0));
    // No spot, or half of one: by elevator, as before.
    expect(spotFrom(Uri.parse('/ws?floor=a')), isNull);
    expect(spotFrom(Uri.parse('/ws?x=1')), isNull);
    expect(spotFrom(Uri.parse('/ws?x=1&z=nope')), isNull);
    expect(spotFrom(Uri.parse('/ws?x=&z=2')), isNull);
  });
}
