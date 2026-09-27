import 'dart:io';

import 'package:agent_office_server/src/ptyhost.dart';
import 'package:agent_office_server/src/ptys.dart' show ptyHostCommand;

/// The office's one executable. Only the PTY host is wired up so far; the CLI comes with its port.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == ptyHostCommand) return runPtyHost(args.sublist(1));
  stderr.writeln('agent-office: not yet ported');
  exitCode = 1;
}
