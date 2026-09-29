// Port of tests/seats.test.ts.
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  // Two floors that each have a Queue agent hired at the queue kiosk and a worker at desk 3.
  const agentOffice = [
    (id: 'w-queue-a', deskId: 'station-queue'),
    (id: 'w-desk-a', deskId: 'desk-3'),
    (id: 'w-bag-a', deskId: 'beanbag-1'),
  ];
  const survive = [(id: 'w-queue-b', deskId: 'station-queue'), (id: 'w-desk-b', deskId: 'desk-3')];
  Iterable<String> ids(List<({String id, String deskId})> ws) => ws.map((w) => w.deskId);

  test('an empty floor shows every seat and kiosk free, board agents included', () {
    expect(vacantSeats(const []), deskById.keys.toSet());
  });

  test('riding the elevator between floors that share a kiosk and a desk leaves neither showing free', () {
    for (final (from, to) in [(agentOffice, survive), (survive, agentOffice)]) {
      final before = vacantSeats(ids(from));
      final after = vacantSeats(ids(to));
      // Same kiosk, same desk, different workers: still taken, so no idle Queue agent and no '+'.
      expect(after.contains('station-queue'), isFalse, reason: 'no idle Queue agent beside the hired one');
      expect(after.contains('desk-3'), isFalse, reason: "no '+' over the worker at desk 3");
      for (final w in to) {
        expect(after.contains(w.deskId), isFalse, reason: '${w.deskId} is taken');
      }
      // A seat only the old floor used is free again; the rest are free on both.
      for (final id in deskById.keys) {
        if (!from.any((w) => w.deskId == id) && !to.any((w) => w.deskId == id)) {
          expect(before.contains(id) && after.contains(id), isTrue, reason: '$id is free');
        }
      }
    }
    expect(
      vacantSeats(ids(survive)).contains('beanbag-1'),
      isTrue,
      reason: 'the bean bag only agent-office uses is free on the other floor',
    );
  });

  test('a kiosk shows its idle agent again only once the hired one sent home has got up', () {
    final packing = {'station-queue'};
    // Sent home: gone from the store, but still packing up at the kiosk.
    expect(vacantSeats(const [], packing.contains).contains('station-queue'), isFalse);
    // Up and walking off: the idle agent is back.
    packing.clear();
    expect(vacantSeats(const [], packing.contains).contains('station-queue'), isTrue);
    // Someone new hired there while the last one was still packing: taken either way.
    packing.add('station-queue');
    expect(vacantSeats(const ['station-queue'], packing.contains).contains('station-queue'), isFalse);
  });

  test("you can only sit where you are: the roof's seats up on the roof, the office's on a floor", () {
    expect(seatHere('couch:1', false), isNotNull);
    expect(seatHere('roof-stool-1:0', true), isNotNull);
    expect(seatHere('couch:1', true), isNull, reason: 'no office couch from the roof');
    expect(seatHere('roof-stool-1:0', false), isNull, reason: 'no bar stool from a project floor');
    expect(seatHere('couch:9', false), isNull, reason: 'no such place on the couch');
  });
}
