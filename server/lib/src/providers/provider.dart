// What the office needs from each agent provider: one adapter per provider (see providers.dart), so
// the worker manager never asks which provider a worker runs. What the windows show about each
// (names, models, efforts, spend) is the shared table in office_shared's providers.dart. Ported from
// upstream's src/server/providers/types.ts.

import 'dart:io';

import 'package:office_pty/office_pty.dart' show chmodSync;
import 'package:office_shared/shared.dart';

import '../worker_handle.dart';

export '../worker_handle.dart';

/// What a provider is set up with on one floor (see [ProviderAdapter.prepare]).
class ProviderFloor {
  const ProviderFloor({required this.dataDir, required this.office, this.dshProfile = 'acp'});

  /// The floor's data dir, where hook settings, homes and plugins go.
  final String dataDir;

  /// How hooks run the office's own executable (see hook.dart's officeCommand).
  final List<String> office;

  /// The DSH profile a DeepSeek Harness worker boots (`--dsh-profile`).
  final String dshProfile;
}

/// One run of a worker, for its adapter to turn into a command line.
class LaunchInput {
  LaunchInput({
    required this.h,
    required this.args,
    this.prompt,
    this.resumeSessionId,
    this.station,
    required this.cwd,
    this.setup,
    this.env = const {},
  });

  final WorkerHandle h;

  /// The command line so far: the office's --agent-args when it runs the office's --agent, nothing
  /// otherwise. A fresh copy, its own to change.
  final List<String> args;

  /// Its first message.
  final String? prompt;

  /// The session it carries on, when it's resumed.
  final String? resumeSessionId;

  /// The board it stands by, for a board agent.
  final StationKind? station;

  /// The folder it runs in: its worktree, or the project itself.
  final String cwd;

  /// What [ProviderAdapter.prepare] set up on this floor.
  final Object? setup;

  /// The office's own environment (tests stand one in), to look things up in (a home, say).
  final Map<String, String> env;
}

class LaunchPlan {
  LaunchPlan({required this.args, this.env, this.rotateToken = false, this.finishEnv});

  final List<String> args;

  /// Its own environment, put in ahead of the hiring account's sign-ins.
  final Map<String, String>? env;

  /// Its hooks get a new token for this run.
  final bool rotateToken;

  /// Last changes to its environment just before it starts, which can fail the start with a message
  /// (by throwing: a malformed setting).
  final void Function(Map<String, String> env)? finishEnv;
}

/// The hook route its workers report on, `/hooks/<id>` on the office's loopback hook server.
class ProviderHook {
  const ProviderHook({required this.strictJson, required this.handle});

  /// A body that isn't JSON is turned away (400); otherwise it still counts as the event, with nothing in it.
  final bool strictJson;

  /// One event from one of its workers (running, with the right token). Says whether it was taken.
  final bool Function(WorkerHandle h, String event, Object? payload) handle;
}

class AdapterUsage {
  const AdapterUsage({
    this.transcript = false,
    this.persisted = false,
    this.scan,
    this.scanOnExit = false,
    this.locate,
    this.save,
    this.restore,
  });

  /// The office reads its session's transcript itself (WorkerHandle.tracker) and books it in the budget (see usage.dart).
  final bool transcript;

  /// Its numbers are what it last reported: kept in workers.json.
  final bool persisted;

  /// Reads its numbers afresh.
  final void Function(WorkerHandle h)? scan;

  /// Its process ended: read its numbers once more, for the end of its last turn.
  final bool scanOnExit;

  /// Where its sessions are logged, looked up as it starts (or is picked back up) in `cwd` with `env`.
  final void Function(WorkerHandle h, String cwd, Map<String, String> env)? locate;

  /// What of its state workers.json keeps, and taking that back.
  final Map<String, Object?> Function(Object? state)? save;
  final void Function(Object? state, Map saved)? restore;
}

/// How a provider's worker runs: in a terminal (the default), or over ACP with the office drawing its
/// terminal (see dsh.dart).
enum ProviderTransport { pty, acp }

/// What its desk says when its screen shows it can't be used yet (a first-run screen, not signed in),
/// or null when it can. [early]: it hasn't started, or was already found blocked.
typedef ScreenBlocked = String? Function(String text, bool early);

abstract class ProviderAdapter {
  const ProviderAdapter();

  AgentProvider get id;

  /// Env vars its own sessions set that would make a worker think it's one of their children: no
  /// worker gets them (see childEnv).
  List<String> get scrubEnv => const [];
  List<String> get scrubPrefixes => const [];

  /// Its own state on each of its workers.
  Object? createState() => null;

  /// Once per floor, as its workers' manager starts: writes its hook settings, homes and plugins.
  /// What it returns goes to [launch] (as [LaunchInput.setup]).
  Object? prepare(ProviderFloor floor) => null;

  /// Its command line and environment for one run.
  LaunchPlan launch(LaunchInput input);

  /// A run of one of its workers in `cwd` is over (it ended, or the worker was sent home): what
  /// [launch] put in that folder can go.
  void exited(WorkerHandle h, String cwd) {}

  /// How it runs: in a terminal (the default), or over ACP.
  ProviderTransport get transport => ProviderTransport.pty;

  /// The sign-in a worker hired by an account needs on that account ('claude').
  String? get signIn => null;

  /// It says itself when it's up (a SessionStart hook): until then it's 'starting', and still silent
  /// 12s in, its desk shows this and needs a human. Without it, it's idle as soon as it runs.
  String? get bootHint => null;

  /// A terminal title that's only its own name, not worth showing on its card.
  RegExp? get titleNoise => null;

  /// Resuming a conversation it no longer has exits before it ever starts: a fresh one is started instead.
  bool get freshIfResumeFails => false;

  /// Its hook route, `/hooks/<id>`.
  ProviderHook? get hook => null;

  /// The provider whose hook route its workers report on, when not their own (a custom --agent
  /// speaks Claude Code's).
  AgentProvider? get hooksAs => null;

  /// It reports progress with OSC 9;4 (0 = idle): that catches a turn ending without a hook (Esc).
  bool get screenProgress => false;

  /// Reads its screen for a first-run or sign-in screen (see [ScreenBlocked]); null: it isn't read.
  ScreenBlocked? get screenBlocked => null;

  AdapterUsage? get usage => null;

  /// The office names its workers' tasks (see TaskNamer); the others keep the task their first prompt gives.
  bool get namesTasks => false;
}

/// Writes a file owner-only, whole: to `<file>.tmp`, then renamed over it.
void writePrivate(String file, String data) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(data, flush: true);
  chmodSync(tmp, 0x180); // 0600
  File(tmp).renameSync(file);
}
