// A worker's terminal as the laptops show it. Kept apart from the store (no browser imports), so the
// laptop painter and its tests can use it on the Dart VM.

import '../shared/protocol.dart';

/// A worker's terminal as the laptop on its desk shows it: rows of styled runs (see `screen`).
class ScreenState {
  ScreenState({required this.cols, required this.rows, required this.cursor, this.version = 0});

  final int cols;
  final int rows;
  final Map<int, List<Run>> lines = {};
  (int, int) cursor;
  int version;
}
