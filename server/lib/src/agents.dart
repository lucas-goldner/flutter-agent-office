import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

const openCodeModelMax = 256;

/// Finds the provider represented by the configured executable. Keep this deliberately based on
/// the final path component: --agent may be an absolute path, and Windows paths can be supplied
/// while the office itself is running under a POSIX shell.
AgentProvider configuredProvider(String command) {
  final base = p.posix.basename(command.replaceAll('\\', '/')).toLowerCase().replaceFirst(RegExp(r'\.exe$'), '');
  if (base == 'claude') return AgentProvider.claude;
  if (base == 'opencode') return AgentProvider.opencode;
  if (base == 'codex') return AgentProvider.codex;
  return AgentProvider.custom;
}

final _unsafeChar = RegExp(r'[\s\p{Cc}\p{Cf}]', unicode: true);
final _providerPart = RegExp(r'^[A-Za-z0-9_.][A-Za-z0-9_.-]*$');

/// OpenCode model ids are argv values, so reject anything that could be ambiguous or unsafe.
bool isValidOpenCodeModel(Object? value) {
  if (value is! String || value.isEmpty || value.length > openCodeModelMax) return false;
  if (_unsafeChar.hasMatch(value)) return false;
  final parts = value.split('/');
  return parts.length >= 2 && _providerPart.hasMatch(parts[0]) && parts.skip(1).every((part) => part.isNotEmpty);
}

/// Why [model] can't be used for a worker of this kind and provider, or null when it can (or is absent).
/// [kind] is 'agent' or 'shell'; [model] null means none was requested.
String? validateWorkerModel(WorkerKind kind, AgentProvider? provider, Object? model) {
  if (model == null) return null;
  if (kind == WorkerKind.shell) return 'Shell workers do not have an OpenCode model';
  if (provider != AgentProvider.opencode) return 'Models can only be selected for OpenCode workers';
  if (!isValidOpenCodeModel(model)) return 'Invalid OpenCode model (expected provider/model without whitespace)';
  return null;
}
