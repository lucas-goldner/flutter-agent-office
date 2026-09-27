// Which agent a new worker runs (Claude Code, OpenCode, Codex or a custom command): the provider
// helpers and the picker from ui/provider.ts.

import 'dart:async';

import 'package:flutter/material.dart';

import '../interop/portable.dart';
import '../net/api.dart';
import '../shared/protocol.dart';
import 'theme.dart';

const _providerKey = 'agent-office.provider';

const Map<AgentProvider, String> kProviderLabel = {
  AgentProvider.claude: 'Claude Code',
  AgentProvider.opencode: 'OpenCode',
  AgentProvider.codex: 'Codex',
  AgentProvider.custom: 'Custom',
};

/// Providers the server says this project can start.
List<AgentProvider> supportedProviders(ProjectInfo? project) {
  final values = project?.agentProviders ?? const [];
  if (values.isNotEmpty) return values.toSet().toList();
  return project != null ? [project.defaultProvider] : const [AgentProvider.claude];
}

/// Resolve old workers/tasks that have no provider metadata to the configured default.
AgentProvider resolvedProvider(AgentProvider? provider, ProjectInfo? project) {
  // A worker/task keeps its identity even if the office was later restarted with a
  // configuration that no longer offers that provider.
  if (provider != null) return provider;
  return project?.defaultProvider ?? supportedProviders(project).first;
}

String providerLabel(AgentProvider? provider, ProjectInfo? project) => kProviderLabel[resolvedProvider(provider, project)]!;

enum ProviderUsageState { tracked, waiting, untracked }

/// Distinguishes a provider with no first report from one whose metrics are intentionally unavailable.
ProviderUsageState providerUsageState(AgentProvider? provider, ProjectInfo? project, Usage? usage) => switch (resolvedProvider(provider, project)) {
  AgentProvider.claude || AgentProvider.opencode || AgentProvider.codex => usage != null ? ProviderUsageState.tracked : ProviderUsageState.waiting,
  AgentProvider.custom => usage != null ? ProviderUsageState.tracked : ProviderUsageState.untracked,
};

String providerUsageNote(AgentProvider provider) => switch (provider) {
  AgentProvider.claude => 'Office usage and budget track Claude Code.',
  AgentProvider.codex =>
    'Review Office hooks in /hooks to enable tracking. Codex reports root-session tokens; subagents are excluded and cost is unavailable.',
  AgentProvider.custom => 'Usage is untracked unless compatible Claude Code hooks report it.',
  AgentProvider.opencode => 'OpenCode reports model/provider estimates; they are not billing, and arrive after the first report.',
};

AgentProvider _preferredProvider(List<AgentProvider> options, AgentProvider fallback) {
  final saved = AgentProvider.tryParse(storageGet(_providerKey));
  if (saved != null && options.contains(saved)) return saved;
  return options.contains(fallback) ? fallback : options.first;
}

const kModelMax = 256;
final _badChars = RegExp(r'[\s\p{Cc}\p{Cf}]', unicode: true);
final _modelHead = RegExp(r'^[A-Za-z0-9_.][A-Za-z0-9_.-]*$');

/// An OpenCode model id: provider/model, no whitespace or control characters.
bool validModel(String value) {
  if (value.isEmpty || value.length > kModelMax || _badChars.hasMatch(value)) return false;
  final parts = value.split('/');
  return parts.length >= 2 && _modelHead.hasMatch(parts[0]) && parts.skip(1).every((p) => p.isNotEmpty);
}

List<String>? _modelList;
int _modelListAt = 0;
Future<List<String>>? _modelRequest;

Future<List<String>> fetchOpenCodeModels() {
  final list = _modelList;
  if (list != null && DateTime.now().millisecondsSinceEpoch - _modelListAt < 60000) return Future.value(list);
  return _modelRequest ??= () async {
    try {
      final res = await Api.getJson('/api/agents/opencode/models');
      if (!res.ok) throw Exception('HTTP ${res.status}');
      final models = res.body['models'];
      final valid = models is List
          ? [
              for (final m in models)
                if (m is String && validModel(m)) m,
            ]
          : <String>[];
      _modelList = valid.toSet().toList();
      _modelListAt = DateTime.now().millisecondsSinceEpoch;
      return _modelList!;
    } finally {
      _modelRequest = null;
    }
  }();
}

const _modelInvalid = 'Use provider/model format without whitespace or control characters (up to 256 characters).';

/// The picker's state, read by the window that owns it (like ProviderPicker in provider.ts).
class ProviderPickerController extends ChangeNotifier {
  ProviderPickerController(ProjectInfo? project)
    : options = supportedProviders(project),
      fallback = resolvedProvider(project?.defaultProvider, project) {
    _selected = _preferredProvider(options, fallback);
  }

  final List<AgentProvider> options;
  final AgentProvider fallback;
  late AgentProvider _selected;
  final TextEditingController modelText = TextEditingController();
  String? _modelError;

  AgentProvider get selected => _selected;
  String? get modelError => _modelError;

  set selected(AgentProvider p) {
    _selected = p;
    if (options.contains(p)) storageSet(_providerKey, p.wire);
    notifyListeners();
  }

  AgentProvider value() => options.contains(_selected) ? _selected : fallback;

  /// The optional initial OpenCode model override. Empty or invalid input is omitted.
  String? model() {
    if (_selected != AgentProvider.opencode) return null;
    final v = modelText.text;
    return validModel(v) ? v : null;
  }

  /// Reports a visible field error for an invalid nonempty OpenCode model.
  bool valid() {
    if (_selected != AgentProvider.opencode || modelText.text.isEmpty) {
      _setError(null);
      return true;
    }
    final okay = validModel(modelText.text);
    _setError(okay ? null : _modelInvalid);
    return okay;
  }

  void _setError(String? e) {
    if (e == _modelError) return;
    _modelError = e;
    notifyListeners();
  }

  void clearError() => _setError(null);

  @override
  void dispose() {
    modelText.dispose();
    super.dispose();
  }
}

/// A provider selector that never offers a provider outside the server's metadata.
/// [compact] stacks it in a column, as the queue's add form and the issue window's footer do.
class ProviderPicker extends StatefulWidget {
  const ProviderPicker({super.key, required this.controller, this.label = 'Worker provider', this.compact = false});

  final ProviderPickerController controller;
  final String label;
  final bool compact;

  @override
  State<ProviderPicker> createState() => _ProviderPickerState();
}

class _ProviderPickerState extends State<ProviderPicker> {
  List<String> _models = const [];
  String _hint = 'Optional provider/model override; suggestions load when OpenCode is selected.';
  AgentProvider? _loadedFor;

  ProviderPickerController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_changed);
    _loadModels();
  }

  @override
  void dispose() {
    c.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    _loadModels();
    if (mounted) setState(() {});
  }

  void _loadModels() {
    if (c.selected != AgentProvider.opencode) {
      _loadedFor = null;
      return;
    }
    if (_loadedFor == AgentProvider.opencode) return;
    _loadedFor = AgentProvider.opencode;
    _hint = _modelList != null
        ? 'Optional provider/model override; choose a suggestion or enter one manually.'
        : 'Loading OpenCode models… You can enter a provider/model manually.';
    fetchOpenCodeModels().then(
      (models) {
        if (!mounted) return;
        setState(() {
          _models = models;
          _hint = 'Optional provider/model override; choose a suggestion or enter one manually.';
        });
      },
      onError: (Object _) {
        if (!mounted) return;
        setState(() => _hint = 'Model suggestions unavailable; enter a provider/model manually if needed.');
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final label = Text(widget.label, style: heavy(widget.compact ? 12 : 14));
    final select = _ProviderSelect(options: c.options, value: c.selected, onChanged: (p) => c.selected = p);
    final note = Text(
      providerUsageNote(c.selected),
      style: heavy(11, color: Swatch.muted, weight: FontWeight.w700),
    );
    final model = c.selected == AgentProvider.opencode ? _modelChoice() : null;
    if (widget.compact) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 2,
        children: [
          label,
          select,
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 155), child: note),
          ?model,
        ],
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          label,
          select,
          ConstrainedBox(constraints: const BoxConstraints(minWidth: 160, maxWidth: 360), child: note),
          ?model,
        ],
      ),
    );
  }

  Widget _modelChoice() => SizedBox(
    width: 300,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: 3,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('OpenCode model', style: heavy(12)),
        ),
        _ModelField(controller: c, models: _models),
        Text(
          c.modelError ?? _hint,
          style: heavy(11, color: c.modelError != null ? Swatch.bad : Swatch.muted, weight: FontWeight.w700),
        ),
      ],
    ),
  );
}

/// The .provider-select: a small white box with a 2px ink border.
class _ProviderSelect extends StatelessWidget {
  const _ProviderSelect({required this.options, required this.value, required this.onChanged});

  final List<AgentProvider> options;
  final AgentProvider value;
  final ValueChanged<AgentProvider> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minWidth: 132),
    padding: const EdgeInsets.symmetric(horizontal: 9),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(9),
      border: Border.all(color: Swatch.ink, width: 2),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<AgentProvider>(
        value: options.contains(value) ? value : options.first,
        isDense: true,
        padding: const EdgeInsets.symmetric(vertical: 6),
        style: heavy(13),
        borderRadius: BorderRadius.circular(9),
        dropdownColor: Colors.white,
        items: [for (final p in options) DropdownMenuItem(value: p, child: Text(kProviderLabel[p]!))],
        onChanged: (p) => p == null ? null : onChanged(p),
      ),
    ),
  );
}

/// The model box with its suggestions (the <datalist> of the old picker).
class _ModelField extends StatefulWidget {
  const _ModelField({required this.controller, required this.models});

  final ProviderPickerController controller;
  final List<String> models;

  @override
  State<_ModelField> createState() => _ModelFieldState();
}

class _ModelFieldState extends State<_ModelField> {
  final _focus = FocusNode();

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final models = widget.models;
    OutlineInputBorder box(Color c) => OutlineInputBorder(
      borderRadius: BorderRadius.circular(9),
      borderSide: BorderSide(color: c, width: 2),
    );
    final bad = controller.modelError != null;
    return RawAutocomplete<String>(
      textEditingController: controller.modelText,
      focusNode: _focus,
      optionsBuilder: (v) {
        final q = v.text.toLowerCase();
        return models.where((m) => m.toLowerCase().contains(q)).take(50);
      },
      fieldViewBuilder: (context, text, focus, onSubmit) => TextField(
        controller: text,
        focusNode: focus,
        maxLength: kModelMax,
        autocorrect: false,
        style: heavy(13, weight: FontWeight.w600),
        onChanged: (_) => controller.clearError(),
        decoration: InputDecoration(
          counterText: '',
          hintText: 'Default (OpenCode settings)',
          contentPadding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
          border: box(bad ? Swatch.bad : Swatch.ink),
          enabledBorder: box(bad ? Swatch.bad : Swatch.ink),
          focusedBorder: box(bad ? Swatch.bad : Swatch.accent),
        ),
      ),
      optionsViewBuilder: (context, onSelected, options) => Align(
        alignment: Alignment.topLeft,
        child: Material(
          elevation: 4,
          borderRadius: BorderRadius.circular(9),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220, maxWidth: 300),
            child: ListView(
              padding: EdgeInsets.zero,
              shrinkWrap: true,
              children: [
                for (final o in options)
                  InkWell(
                    onTap: () => onSelected(o),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Text(o, style: heavy(13, weight: FontWeight.w600)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
