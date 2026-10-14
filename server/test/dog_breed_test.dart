import 'dart:convert';
import 'dart:io';

import 'package:agent_office_server/src/dog.dart';
import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Port of upstream's tests/dog-breed.test.ts.
void main() {
  final env = DogEnv(workers: () => const [], people: () => const [], send: (_) {});

  test("a floor's dog is the breed and coat someone picked, and stays so after a restart", () {
    final dir = Directory.systemTemp.createTempSync('dog-breed-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final dog = Dog('floor-a', dir.path, env);
    expect(dog.view().breed, dogDefaults('floor-a').breed);
    expect(dog.view().coat, dogDefaults('floor-a').coat);
    final other = dogDefaults('floor-a').breed == DogBreed.shiba ? DogBreed.pug : DogBreed.shiba;
    expect(dog.setBreed(other.wire), other);
    expect(dog.setBreed('wolf'), isNull);
    expect(dog.setCoat(6), isTrue);
    expect(dog.setCoat(99), isFalse);
    expect(dog.setCoat(1.5), isFalse);
    expect(dog.setCoat('2'), isFalse);
    dog.rename('Pipoca');
    dog.stop();
    expect(jsonDecode(File(p.join(dir.path, 'dog.json')).readAsStringSync()), {
      'name': 'Pipoca',
      'breed': other.wire,
      'coat': 6,
    });
    final again = Dog('floor-a', dir.path, env);
    expect(again.view().breed, other);
    expect(again.view().name, 'Pipoca');
    expect(again.view().coat, 6);
    expect(again.view().toJson()['breed'], other.wire);
    again.stop();
    // A dog.json from before breeds (just its name) keeps the floor's own breed and coat.
    File(p.join(dir.path, 'dog.json')).writeAsStringSync(jsonEncode({'name': 'Rex', 'coat': 'red'}));
    final old = Dog('floor-a', dir.path, env);
    expect(
      [old.view().name, old.view().breed, old.view().coat],
      ['Rex', dogDefaults('floor-a').breed, dogDefaults('floor-a').coat],
    );
    old.stop();
  });
}
