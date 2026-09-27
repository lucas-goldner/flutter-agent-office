# xterm_core

The `Terminal`, buffer and escape parser of [xterm.dart](https://github.com/TerminalStudio/xterm.dart) 4.0.0 (MIT, see LICENSE), vendored unchanged apart from the package name and without the Flutter view, because the published package depends on the Flutter SDK and the office server is plain Dart. The server runs one per worker to keep its screen and scrollback, the way the Node server used `@xterm/headless`.
