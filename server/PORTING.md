# Porting the Node server to Dart

The server in `src/server/*.ts` is being rewritten here, in `server/`, so the office needs neither
Node nor npm. The TypeScript stays in place until the cutover as the reference: port **behaviour**
faithfully (same wire messages, same files on disk, same CLI flags and output), not line by line.

## Layout

- One Dart file per TypeScript module, snake_cased: `src/server/codex-usage.ts` →
  `server/lib/src/codex_usage.dart`. Keep the same public names (`TypeName`, `functionName`) and
  near-identical signatures so modules that import each other line up without coordination.
- Tests: `tests/foo.test.ts` → `server/test/foo_test.dart` (`package:test`). Port every case.
- `server/bin/agent_office.dart` is the one executable (CLI, server, the PTY host and the hook
  helper are all subcommands of it), compiled with `dart compile exe`.

## Packages

- Wire types come from `package:office_shared` (`packages/office_shared`, also used by the Flutter
  client): `WorkerInfo`, `ServerMsg` subclasses, `layout`, `nav`, … Use them rather than
  re-declaring; each has `toJson()`/`fromJson`. If a type the server needs is missing or lacks a
  direction, add it there (tolerant readers, writers that omit nulls) and keep its tests passing.
- HTTP and WebSockets: `package:relic` (`relic_io` adapter).
- PTYs: `package:pty2` (`PseudoTerminal.start`). Terminal state: `package:xterm_core` (the vendored
  xterm.dart core), standing in for `@xterm/headless` + `addon-serialize`.
- Crypto: `package:crypto` (sha256, HMAC), `package:pointycastle` (scrypt; must verify hashes the
  Node server wrote: Node's scrypt defaults N=16384, r=8, p=1).
- Child processes: `dart:io` `Process.run` / `Process.start`. Unix sockets: `dart:io`
  (`InternetAddress(path, type: InternetAddressType.unix)`).

## Style

- `dart format` at page width 120 (set in analysis_options.yaml); `dart analyze` must be clean.
- Comments like the TypeScript's: say why, in plain sentences; keep the useful ones when porting.
- Files the office writes (`.agent-office/*.json`, scrollback, …) keep the exact same names and
  JSON shape, so an office upgraded from the Node server carries on with its data.
- Write JSON files the way the TS does (to `<file>.tmp`, then rename).
- Synchronous `dart:io` calls are fine where the TS used the sync Node calls.
