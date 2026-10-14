import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/drops.dart';
import 'package:office_shared/drops.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('a dropped file keeps a name that is safe to type into a terminal', () {
    expect(
      dropName('Screenshot 2026-09-29 at 10.02.03\u202fAM.png', 'image/png'),
      'Screenshot-2026-09-29-at-10.02.03-AM.png',
    );
    expect(dropName('résumé (final).PDF', 'application/pdf'), 'resume-final.pdf');
    expect(dropName('../../etc/passwd', ''), 'passwd');
    expect(dropName('C:\\Users\\sam\\shot.jpeg', 'image/jpeg'), 'shot.jpeg');
    expect(dropName(r'$(rm -rf ~);.png', 'image/png'), 'rm--rf.png');
  });

  test('a picture dropped without a name ending gets one, so the agent sees a picture', () {
    expect(dropName('image', 'image/png'), 'image.png');
    expect(dropName('', 'image/jpeg'), 'file.jpg');
    expect(dropName('.env', 'text/plain'), 'env');
    expect(dropName('notes', 'text/plain'), 'notes');
    expect(dropName('shot', 'image/webp; charset=binary'), 'shot.webp');
  });

  test('dropped paths are typed the way a terminal types a dragged file', () {
    expect(
      droppedPaths(['/home/sam/proj/.agent-office/drops/w1/ab-shot.png']),
      '/home/sam/proj/.agent-office/drops/w1/ab-shot.png',
    );
    expect(droppedPaths(['/Users/sam/my proj/a.png', '/tmp/b.png']), r'/Users/sam/my\ proj/a.png /tmp/b.png');
    expect(droppedPaths(["/Users/sam/it's (new)/café.png"]), r"/Users/sam/it\'s\ \(new\)/café.png");
    expect(droppedPaths([r'C:\Users\sam\proj\a.png']), r'C:\Users\sam\proj\a.png');
    expect(droppedPaths([r'C:\Users\sam\my proj\a.png']), r'"C:\Users\sam\my proj\a.png"');
  });

  test("each worker's drops are kept apart and go when the worker does", () {
    final dir = Directory.systemTemp.createTempSync('agent-office-drops-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final store = DropStore(dir.path);
    final a = store.save('w1', 'shot.png', 'image/png', utf8.encode('one'));
    final b = store.save('w1', 'shot.png', 'image/png', utf8.encode('two'));
    final c = store.save('w2', 'image', 'image/png', utf8.encode('three'));
    expect([a, b, c], everyElement(isNotNull));
    expect(a, isNot(b));
    expect(File(a!).readAsStringSync(), 'one');
    expect(File(b!).readAsStringSync(), 'two');
    expect(p.basename(c!), matches(RegExp(r'^[0-9a-f]{8}-image\.png$')));
    if (!Platform.isWindows) expect(File(a).statSync().mode & 0x1ff, 0x180); // 0600
    expect(store.save('../w1', 'x.png', 'image/png', utf8.encode('x')), isNull);

    store.remove('w1');
    expect(File(a).existsSync() || File(b).existsSync(), isFalse);
    expect(File(c).existsSync(), isTrue);
    store.prune({'w3'});
    expect(File(c).existsSync(), isFalse);
  });
}
