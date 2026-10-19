// No drag and drop of files off the web (yet): the desktop app has no drop plugin. Its clipboard's files
// and pictures come from the macOS runner (MainFlutterWindow.swift, channel agent_office/clipboard).

import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'drops.dart';

const _clipboard = MethodChannel('agent_office/clipboard');

Future<List<DroppedFile>> clipboardFiles() async {
  if (!Platform.isMacOS) return const [];
  try {
    final got = await _clipboard.invokeListMethod<Object?>('files') ?? const [];
    return [
      for (final f in got)
        if (f is List && f.length == 3 && f[2] is Uint8List)
          DroppedFile(
            name: '${f[0]}',
            type: '${f[1]}',
            size: (f[2] as Uint8List).length,
            bytes: () async => f[2] as Uint8List,
          ),
    ];
  } on MissingPluginException {
    return const []; // an older build of the app, without the channel
  } catch (_) {
    return const [];
  }
}

void Function() watchDrops({
  required bool Function() active,
  required void Function(bool over) over,
  required void Function(List<DroppedFile> files) dropped,
}) => () {};

void Function() watchPastedFiles(bool Function() active, void Function(List<DroppedFile> files) pasted) => () {};
