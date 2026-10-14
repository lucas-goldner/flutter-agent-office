// The shared part of tests/drops.test.ts (dropped file names and the store are the server's).
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('dropped paths are typed the way a terminal types a dragged file', () {
    expect(
      droppedPaths(['/home/sam/proj/.agent-office/drops/w1/ab-shot.png']),
      '/home/sam/proj/.agent-office/drops/w1/ab-shot.png',
    );
    expect(droppedPaths(['/Users/sam/my proj/a.png', '/tmp/b.png']), r'/Users/sam/my\ proj/a.png /tmp/b.png');
    expect(droppedPaths(["/Users/sam/it's (new)/café.png"]), r"/Users/sam/it\'s\ \(new\)/café.png");
    expect(droppedPaths([r'C:\Users\sam\proj\a.png']), r'C:\Users\sam\proj\a.png');
    expect(droppedPaths([r'C:\Users\sam\my proj\a.png']), r'"C:\Users\sam\my proj\a.png"');
    expect(dropMaxBytes, 25 * 1024 * 1024);
  });
}
