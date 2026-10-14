import 'dart:io';

import 'package:agent_office/world/dog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:office_shared/dog.dart';

void main() {
  test('every breed has its model', () {
    for (final b in dogBreeds) {
      expect(File(dogModel(b).asset).existsSync(), isTrue, reason: b.wire);
      expect(dogModel(b).preload, isFalse, reason: 'a floor only ever has the one breed: loaded when needed');
    }
  });

  test('on its way somewhere it trots, and in a hurry it gallops; otherwise the clip is what it does', () {
    expect(dogClip(DogMotion.walk, 1.3), 'walk');
    expect(dogClip(DogMotion.walk, 2.7), 'run');
    for (final m in DogMotion.values.where((m) => m != DogMotion.walk)) {
      expect(dogClip(m, 0), m.name);
    }
    // Played at its speed over these, its paws keep pace with the floor.
    expect(dogStrideSpeed.keys, {'walk', 'run'});
  });

  test('the coat: three colours, and only the white one glows', () {
    for (var n = 0; n < dogCoats.length; n++) {
      final paint = dogCoatPaint(n);
      expect(paint, hasLength(3));
      final glows = paint.any((p) => p.emissive.r > 0 || p.emissive.g > 0 || p.emissive.b > 0);
      expect(glows, dogCoatNames[n] == 'White', reason: dogCoatNames[n]);
    }
    expect(dogCoatPaint(dogCoats.length).first.color, dogCoatPaint(0).first.color, reason: 'wraps round');
  });

  test('every part of the model is painted: a coat colour or a fixed one', () {
    expect(dogPaint.values.whereType<int>().toSet(), {0, 1, 2});
    expect(dogPaint.keys, containsAll(['Fur', 'Light', 'Ear', 'Nose', 'Collar']));
  });
}
