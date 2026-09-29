import 'dart:io';

import 'package:agent_office_server/src/theme.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('agent-office-theme-'));
  tearDown(() => dir.deleteSync(recursive: true));

  final october = DateTime.utc(2026, 10, 12).millisecondsSinceEpoch;
  final june = DateTime.utc(2026, 6, 12).millisecondsSinceEpoch;

  test('auto follows the calendar at the office, and a pick is kept on disk', () {
    var now = october;
    final told = <ThemeState>[];
    final themes = Themes(dir.path, () => 0, told.add, now: () => now);
    expect(themes.state().toJson(), {'pick': 'auto', 'active': 'halloween'});

    now = june;
    themes.emit();
    expect(told.single.active, isNull);
    themes.emit();
    expect(told, hasLength(1));

    themes.set(ThemePick.christmas, 'Ada');
    expect(told.last.toJson(), {'pick': 'christmas', 'active': 'christmas', 'by': 'Ada', 'at': june});
    expect(File(p.join(dir.path, 'theme.json')).existsSync(), isTrue);

    final again = Themes(dir.path, () => 0, (_) {}, now: () => now);
    expect(again.state().pick, ThemePick.christmas);
    expect(again.state().by, 'Ada');
  });

  test('a bad file is the default', () {
    File(p.join(dir.path, 'theme.json')).writeAsStringSync('{"pick": "easter"}');
    expect(Themes(dir.path, () => 0, (_) {}, now: () => june).state().toJson(), {'pick': 'auto', 'active': null});
  });
}
