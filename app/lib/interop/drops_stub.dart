// No drag and drop of files off the web (yet): the desktop app has no drop plugin.

import 'drops.dart';

void Function() watchDrops({
  required bool Function() active,
  required void Function(bool over) over,
  required void Function(List<DroppedFile> files) dropped,
}) => () {};

void Function() watchPastedFiles(bool Function() active, void Function(List<DroppedFile> files) pasted) => () {};
