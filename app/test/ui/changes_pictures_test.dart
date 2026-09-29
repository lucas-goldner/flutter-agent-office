import 'package:agent_office/ui/changes_logic.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/protocol.dart';

ChangedFile _f(ChangeStatus status, {String path = 'img/logo.png'}) =>
    ChangedFile(path: path, status: status, additions: 0, deletions: 0, binary: true, uncommitted: true, sig: 'abc 1');

void main() {
  test('new and deleted pictures have one side, the rest both', () {
    expect(pictureSides(_f(ChangeStatus.untracked)), ['new']);
    expect(pictureSides(_f(ChangeStatus.added)), ['new']);
    expect(pictureSides(_f(ChangeStatus.deleted)), ['old']);
    expect(pictureSides(_f(ChangeStatus.modified)), ['old', 'new']);
    expect(pictureSides(_f(ChangeStatus.renamed)), ['old', 'new']);
  });

  test('a picture loads from /api/changes/file with its signature', () {
    final u = Uri.parse(pictureUrl('floor-2', 'w1', _f(ChangeStatus.modified, path: 'a b/c.png'), 'old'));
    expect(u.path, '/api/changes/file');
    expect(u.queryParameters, {'floor': 'floor-2', 'worker': 'w1', 'path': 'a b/c.png', 'side': 'old', 'v': 'abc 1'});
    expect(Uri.parse(pictureUrl(null, 'w1', _f(ChangeStatus.added), 'new')).queryParameters['floor'], '');
  });

  test('which files are pictures', () {
    expect(changedImageType('a/B.PNG'), 'image/png');
    expect(changedImageType('icon.svg'), 'image/svg+xml');
    expect(changedImageType('main.dart'), isNull);
    expect(changedImageType('.png'), isNull);
  });
}
