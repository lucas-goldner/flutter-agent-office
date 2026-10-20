import 'package:agent_office/world/office/build_tower.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/codemagic.dart';

void main() {
  test('the stack light: off with no builds, yellow while any runs, else the newest one: green or red', () {
    CodemagicBuild b(String id, CodemagicStatus s) => CodemagicBuild(id: id, workflow: 'iOS dev', status: s);
    expect(towerLight(const CodemagicState()), TowerLight.off);
    expect(
      towerLight(CodemagicState(builds: [b('2', CodemagicStatus.finished), b('1', CodemagicStatus.building)])),
      TowerLight.yellow,
    );
    expect(
      towerLight(CodemagicState(builds: [b('2', CodemagicStatus.finished), b('1', CodemagicStatus.failed)])),
      TowerLight.green,
    );
    expect(
      towerLight(CodemagicState(builds: [b('2', CodemagicStatus.timeout), b('1', CodemagicStatus.finished)])),
      TowerLight.red,
    );
  });
}
