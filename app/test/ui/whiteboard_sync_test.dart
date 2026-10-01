// The whiteboard's syncing (whiteboard_sync.dart), shared by the browser's JS-interop driver and the
// desktop app's web view: driven here through a fake Excalidraw that answers like the bridge does.

import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:agent_office/net/api.dart';
import 'package:agent_office/state/store.dart';
import 'package:agent_office/ui/whiteboard_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';
import 'package:office_shared/whiteboard.dart';

Map<String, dynamic> raw(String id, int version, {String type = 'rectangle', String? fileId, bool deleted = false, String text = ''}) => {
  'id': id,
  'type': type,
  'version': version,
  'versionNonce': version * 7,
  'isDeleted': deleted,
  'fileId': ?fileId,
  'text': text,
};

/// Excalidraw as the sync sees it: [changes] is what takeChanges hands over next, [pictures] what
/// it has, and every call is written down.
class FakeExcalidraw implements ExcalidrawDriver {
  final List<String> calls = [];
  List<Map<String, dynamic>> changes = [];
  final Set<String> pictures = {};
  final Map<String, String> files = {};
  final List<String> merged = [];
  final List<List<dynamic>> collaborators = [];

  @override
  Future<String> takeChanges(bool all) async {
    calls.add('takeChanges($all)');
    final out = changes;
    changes = [];
    return out.isEmpty ? '' : jsonEncode(out);
  }

  @override
  void merge(String json) {
    calls.add('merge');
    merged.add(json);
  }

  @override
  Future<String> file(String id) async {
    calls.add('file($id)');
    return files[id] ?? '';
  }

  @override
  void setCollaborators(String json) => collaborators.add(jsonDecode(json) as List);

  @override
  Future<String> missingFiles(String json) async => jsonEncode([
    for (final el in jsonDecode(json) as List)
      if (el['type'] == 'image' && el['isDeleted'] != true && el['fileId'] != null && !pictures.contains(el['fileId'])) el['fileId'],
  ]);

  @override
  void addFiles(String json) {
    calls.add('addFiles');
    for (final f in jsonDecode(json) as List) {
      pictures.add(f['id'] as String);
    }
  }

  @override
  Future<ui.Image?> renderPreview(String json, int maxW, int maxH) async => null;
}

class Harness {
  Harness() {
    store.floor = 'f1';
    store.you = 'me';
    files = WbFiles(
      floor: () => store.floor ?? '',
      fetch: (path) async {
        fetched.add(path);
        final id = Uri.parse(path).queryParameters['id']!;
        return office[id];
      },
      upload: (path, body) async {
        uploaded.add(body['id'] as String);
        if (refuse) return ApiResult(413, {'error': 'Too big'});
        office[body['id'] as String] = jsonEncode(body);
        return ApiResult(200, {'ok': true});
      },
      warn: warnings.add,
    );
    sync = WhiteboardSync(driver: ex, store: store, send: sent.add, files: files, warn: warnings.add);
  }

  final store = Store();
  final ex = FakeExcalidraw();
  final sent = <ClientMsg>[];
  final warnings = <String>[];
  final fetched = <String>[];
  final uploaded = <String>[];
  final office = <String, String>{};
  bool refuse = false;
  late final WbFiles files;
  late final WhiteboardSync sync;

  List<String> sentIds() => [
    for (final m in sent)
      if (m is WbUpdateCmd) ...m.elements.map((e) => e.id),
  ];
}

/// Past the send timer (50 ms) and whatever it starts.
Future<void> settle([int ms = 80]) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('nothing is taken or merged before Excalidraw is up; then it gets the board and its pictures', () async {
    final h = Harness();
    h.store.drew([WbElement(raw('a', 1)), WbElement(raw('pic', 1, type: 'image', fileId: 'f-1'))]);
    h.office['f-1'] = jsonEncode({'id': 'f-1', 'mimeType': 'image/png', 'dataURL': 'data:image/png;base64,AA==', 'created': 1});
    h.sync.changed();
    h.sync.route(WbUpdateMsg([WbElement(raw('b', 1))]));
    await settle();
    expect(h.ex.calls, isEmpty);

    h.sync.start();
    await settle();
    expect(h.ex.merged, hasLength(1));
    expect((jsonDecode(h.ex.merged.single) as List).map((e) => e['id']), containsAll(['a', 'pic']));
    expect(h.fetched, ['/api/whiteboard/file?floor=f1&id=f-1']);
    expect(h.ex.pictures, {'f-1'});
    expect(h.files.stored, {'f-1'});
    expect(h.ex.collaborators, [[]], reason: 'everyone else drawing (nobody yet)');
  });

  test('your changes go out a moment later, only those newer than the office has', () async {
    final h = Harness()..sync.start();
    h.store.drew([WbElement(raw('a', 2))]);
    h.ex.changes = [raw('a', 2), raw('b', 1)];
    h.sync.changed();
    h.sync.changed();
    expect(h.sent, isEmpty);
    await settle();
    expect(h.ex.calls.where((c) => c.startsWith('takeChanges')), ['takeChanges(false)'], reason: 'one flush for both');
    expect(h.sentIds(), ['b']);
    expect(h.store.whiteboard['b']!.version, 1, reason: 'the store has what you sent');
  });

  test('a picture goes up before the element that shows it', () async {
    final h = Harness()..sync.start();
    h.ex.files['f-2'] = jsonEncode({'id': 'f-2', 'mimeType': 'image/png', 'dataURL': 'data:image/png;base64,AA==', 'created': 1});
    h.ex.changes = [raw('img', 1, type: 'image', fileId: 'f-2'), raw('r', 1)];
    h.sync.changed();
    await settle(200);
    expect(h.uploaded, ['f-2']);
    expect(h.sentIds(), ['r', 'img'], reason: 'the rectangle straight away, the image once its picture is up');
    expect(h.ex.calls.where((c) => c == 'file(f-2)'), hasLength(1));
  });

  test("a picture the office refuses is said so, and its element stays yours", () async {
    final h = Harness()..sync.start();
    h.refuse = true;
    h.ex.files['f-3'] = jsonEncode({'id': 'f-3', 'mimeType': 'image/png', 'dataURL': 'data:,', 'created': 1});
    h.ex.changes = [raw('img', 1, type: 'image', fileId: 'f-3')];
    h.sync.changed();
    await settle(200);
    expect(h.warnings, ['Too big']);
    expect(h.sentIds(), isEmpty);
    expect(h.sync.pending.keys, ['img']);
  });

  test('an element too big for the office stays on your screen, and you hear about it once', () async {
    final h = Harness()..sync.start();
    final big = 'x' * (wbMaxElementBytes + 10);
    h.ex.changes = [raw('big', 1, text: big), raw('ok', 1)];
    h.sync.changed();
    await settle();
    h.ex.changes = [raw('big', 2, text: big)];
    h.sync.changed();
    await settle();
    expect(h.sentIds(), ['ok']);
    expect(h.warnings, hasLength(1));
  });

  test("everyone else's drawing is merged, and their cursors shown", () async {
    final h = Harness()..sync.start();
    h.store.peers = {'bob': PeerInfo.fromJson({'id': 'bob', 'name': 'Bob', 'color': '#118ab2'})};
    h.store.drawing = ['me', 'bob'];
    await settle(30);
    h.ex.merged.clear();
    h.ex.collaborators.clear();
    h.sync.route(WbUpdateMsg([WbElement(raw('c', 3))]));
    expect((jsonDecode(h.ex.merged.single) as List).single['id'], 'c');
    h.sync.route(WbPointerMsg('bob', WbPointer(x: 10, y: 20, tool: WbTool.parse('pointer'), button: WbButton.parse('down')), selected: ['c']));
    await settle(30);
    expect(h.ex.collaborators.last, [
      {'id': 'bob', 'name': 'Bob', 'color': '#118ab2', 'x': 10, 'y': 20, 'tool': 'pointer', 'button': 'down', 'selected': ['c']},
    ]);
    h.sync.route(const WbPeopleMsg(['me']));
    h.store.drawing = ['me'];
    await settle(30);
    expect(h.ex.collaborators.last, isEmpty);
  });

  test('your pointer goes out as you move it', () {
    final h = Harness()..sync.start();
    h.sync.pointer(1.5, 2.5, 'laser', 'up', ['a']);
    final m = h.sent.single as WbPointerCmd;
    expect(m.fields, {'x': 1.5, 'y': 2.5, 'tool': 'laser', 'button': 'up', 'selected': ['a']});
  });

  test('back from a dropped connection: the board is merged, and everything you have goes out again', () async {
    final h = Harness()..sync.start();
    h.ex.calls.clear();
    h.ex.changes = [raw('a', 1)];
    h.sync.reconnected();
    await settle(10);
    expect(h.ex.calls, ['takeChanges(true)']);
    expect(h.sentIds(), ['a']);
  });

  test("closing takes what you drew last before Excalidraw goes away, and nothing after", () async {
    final h = Harness()..sync.start();
    h.ex.calls.clear();
    h.ex.changes = [raw('last', 1)];
    h.sync.changed();
    h.sync.close();
    expect(h.ex.calls, ['takeChanges(false)'], reason: 'asked synchronously, ahead of the unmount');
    await settle();
    expect(h.sentIds(), ['last']);
    h.sync.changed();
    h.sync.route(WbUpdateMsg([WbElement(raw('z', 1))]));
    await settle();
    expect(h.ex.calls, ['takeChanges(false)']);
  });

  test("a picture the office hasn't got isn't asked for again straight away", () async {
    final h = Harness();
    final page = FakeExcalidraw();
    final json = jsonEncode([raw('p', 1, type: 'image', fileId: 'gone')]);
    await h.files.load(page, json);
    await h.files.load(page, json);
    expect(h.fetched, hasLength(1));
    expect(page.calls, isEmpty);
  });

  test('a picture is put up once even when asked for again meanwhile', () async {
    final h = Harness();
    final gate = Completer<String>();
    var reads = 0;
    Future<String> read() {
      reads++;
      return gate.future;
    }

    final a = h.files.put('f', read), b = h.files.put('f', read);
    gate.complete(jsonEncode({'id': 'f', 'mimeType': 'image/png', 'dataURL': 'data:,', 'created': 1}));
    expect(await a, isTrue);
    expect(await b, isTrue);
    expect(reads, 1);
    expect(h.uploaded, ['f']);
    // Excalidraw not having it yet isn't remembered: the next change asks again.
    expect(await h.files.put('g', () async => ''), isFalse);
    expect(await h.files.put('g', () async => jsonEncode({'id': 'g'})), isTrue);
  });
}
