# The office server

The office's server, in Dart: it serves the Flutter client (`app/`), speaks the WebSocket protocol in
`packages/office_shared`, and runs every worker's terminal. It used to be a Node/TypeScript server;
it was ported module by module, keeping the same wire messages, files on disk and CLI flags, so an
office that ran on the Node server carries on with its data, sessions and workers.

## Layout

- `bin/agent_office.dart` is the one executable, compiled with `dart compile exe` by
  `tool/build.dart`. It is the server, and its subcommands are the PTY host (`__ptyhost`), the
  agents' status hook (`hook`), `setup` (the first-start walkthrough, `setup.dart`), `prune` and
  `accounts`.
- `lib/src/server.dart` is the HTTP and WebSocket server (on `package:relic`); the other modules
  in `lib/src` are the pieces it wires together: `workers.dart` and `ptys.dart`/`ptyhost.dart` the
  workers and their terminals, `floor.dart` everything one floor (project) has, `config.dart`,
  `auth.dart` and `accounts.dart` settings and sign-in, and so on.
- `test/` is `package:test`: `dart test` (several minutes; the PTY tests start real hosts, each compiled
  under `dart run`).

## Packages

- Wire types: `package:office_shared` (`packages/office_shared`), shared with the Flutter client.
- PTYs: `package:office_pty` (`packages/office_pty`), pty2's Unix core reworked to give the child
  its pid, a clean signal state and its exact environment. Terminal state: `package:xterm_core`
  (`packages/xterm_core`, the xterm.dart core without Flutter) plus `lib/src/headless.dart`'s
  serializer, which makes the snapshots browsers replay.
- Crypto: `package:crypto` and `package:pointycastle` (scrypt with Node's old defaults, N=16384,
  r=8, p=1, so existing password hashes keep verifying).

## Conventions

- `dart format` at page width 120; `dart analyze` clean.
- Files the office writes (`.agent-office/*.json`, scrollback, …) keep their names and JSON shape;
  they're written to `<file>.tmp` and renamed.
- After changing `ptyhost.dart`, bump `ptyProtocol` in `ptys.dart`: the next server then replaces
  the running host (its workers resume their sessions).
