// 🏗️ Codemagic: the floor's app builds. The build tower's window (start a workflow on a
// branch, follow the builds started from the office, open one on Codemagic) and ⚙️ Settings →
// 🏗️ Codemagic (admins pick the floor's app). The token stays on the office's server.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:office_shared/codemagic.dart';
import 'package:office_shared/protocol.dart';

import '../interop/portable.dart';
import '../net/api.dart';
import '../office_scope.dart';
import '../state/store.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

const _branchKey = 'agent-office.codemagic-branch';

/// Opens the build tower's window.
ModalHandle openCodemagic(OfficeScope scope) =>
    ModalStack.instance.show((modal) => _CodemagicWindow(modal: modal, scope: scope))..doing = '🏗️ at the build tower';

/// How long ago, or how long it took, in words: "3 min", "1 h 5 min".
String buildDuration(int ms) {
  final m = (ms / 60000).round();
  if (m < 1) return '<1 min';
  return m < 60 ? '$m min' : '${m ~/ 60} h${m % 60 > 0 ? ' ${m % 60} min' : ''}';
}

class _CodemagicWindow extends StatefulWidget {
  const _CodemagicWindow({required this.modal, required this.scope});
  final ModalHandle modal;
  final OfficeScope scope;

  @override
  State<_CodemagicWindow> createState() => _CodemagicWindowState();
}

class _CodemagicWindowState extends State<_CodemagicWindow> {
  Store get store => widget.scope.store;
  late final _branch = TextEditingController(text: storageGet(_branchKey) ?? '');

  @override
  void dispose() {
    _branch.dispose();
    super.dispose();
  }

  void _build(CodemagicWorkflow w) {
    final b = _branch.text.trim();
    if (b.isEmpty) return;
    storageSet(_branchKey, b);
    widget.scope.net.send(CodemagicBuildCmd(w.id, branch: b));
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.topics(const [Topic.codemagic]),
    builder: (context, _) {
      final s = store.codemagic;
      return ModalWindow(
        modal: widget.modal,
        width: 760,
        title: Text(s.appName.isNotEmpty ? '🏗️ ${s.appName}' : '🏗️ Codemagic'),
        body: !s.token
            ? const Note(
                'The office has no Codemagic token: start it with CODEMAGIC_TOKEN set, or --codemagic-token (Codemagic → Team settings → Integrations → Codemagic API).',
                top: 0,
              )
            : s.appId.isEmpty
            ? const Note('No app for this floor yet: an admin picks one in ⚙️ Settings → 🏗️ Codemagic.', top: 0)
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const FieldLabel('Start a build', top: 0),
                  BoxInput(
                    key: const ValueKey('codemagic-branch'),
                    controller: _branch,
                    hint: 'The branch to build, e.g. feature/qr-blank',
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final w in s.workflows)
                        ListenableBuilder(
                          listenable: _branch,
                          builder: (context, _) => OfficeButton(
                            key: ValueKey('codemagic-build-${w.id}'),
                            label: '▶ ${w.label}',
                            kind: BtnKind.primary,
                            tooltip: _branch.text.trim().isEmpty
                                ? 'Type a branch first'
                                : 'Build ${_branch.text.trim()} with ${w.label}',
                            onPressed: _branch.text.trim().isEmpty ? null : () => _build(w),
                          ),
                        ),
                    ],
                  ),
                  if (s.workflows.isEmpty) const Note('The app has no workflows on Codemagic yet.'),
                  const FieldLabel('Builds from the office', top: 18),
                  if (s.builds.isEmpty)
                    Note('None yet. Workers start them with agent-office codemagic build, too.', top: 0),
                  for (final b in s.builds) _buildRow(b),
                  if (s.error != null) Note('⚠️ ${s.error}', bad: true),
                ],
              ),
      );
    },
  );

  Widget _buildRow(CodemagicBuild b) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final took = b.finishedAt > 0
        ? 'took ${buildDuration(b.finishedAt - b.at)}'
        : (b.at > 0 ? 'running ${buildDuration(now - b.at)}' : '');
    return Container(
      key: ValueKey('codemagic-row-${b.id}'),
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        color: b.status.bad ? const Color(0xFFFFF1F1) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Swatch.ink, width: 2),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${b.status.label}  ${b.workflow}${b.index > 0 ? ' #${b.index}' : ''}',
                  style: heavy(14, weight: FontWeight.w900),
                ),
                Text(
                  [
                    b.branch,
                    if (b.by.isNotEmpty) 'by ${b.by}',
                    if (b.at > 0) timeAgo(b.at),
                    if (took.isNotEmpty) took,
                    if (b.artifacts.isNotEmpty) b.artifacts.map((a) => a.name).join(', '),
                  ].join(' · '),
                  style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                ),
              ],
            ),
          ),
          if (b.link.isNotEmpty)
            OfficeButton(
              label: '🌐 Codemagic',
              tooltip: 'Open the build on Codemagic',
              onPressed: () => openInNewTab(b.link),
            ),
        ],
      ),
    );
  }
}

/// ⚙️ Settings → 🏗️ Codemagic: the floor's app (admins pick it from the token's apps).
class CodemagicSettings extends StatefulWidget {
  const CodemagicSettings({super.key, required this.scope});
  final OfficeScope scope;

  @override
  State<CodemagicSettings> createState() => _CodemagicSettingsState();
}

class _CodemagicSettingsState extends State<CodemagicSettings> {
  Store get store => widget.scope.store;
  final _query = TextEditingController();
  List<CodemagicApp>? _apps;
  String? _error;
  bool _picking = false;
  Timer? _debounce;

  @override
  void dispose() {
    _query.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _search([String q = '']) async {
    final r = await Api.getJson('/api/codemagic/apps?q=${Uri.encodeQueryComponent(q)}');
    if (!mounted) return;
    setState(() {
      _error = r.ok ? null : r.error("Couldn't read your Codemagic apps");
      _apps = r.ok
          ? [
              for (final a in r.body['apps'] is List ? r.body['apps'] as List : const [])
                if (a is Map) CodemagicApp.fromJson(Map<String, dynamic>.from(a)),
            ]
          : const [];
    });
  }

  void _pick(String appId) {
    widget.scope.net.send(CodemagicAppCmd(appId));
    setState(() => _picking = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store.topics(const [Topic.codemagic, Topic.me]),
    builder: (context, _) {
      final s = store.codemagic;
      final admin = store.me.admin;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!s.token)
            const Note(
              'Start the office with CODEMAGIC_TOKEN set (or --codemagic-token) to build this floor\'s app on Codemagic.',
              top: 0,
            )
          else ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.appId.isEmpty
                        ? 'No app for this floor'
                        : '📱 ${s.appName} · ${s.workflows.map((w) => w.label).join(', ')}',
                    style: heavy(13.5, weight: FontWeight.w800),
                  ),
                ),
                if (admin) ...[
                  OfficeButton(
                    key: const ValueKey('codemagic-pick'),
                    label: s.appId.isEmpty ? 'Pick the app' : 'Change',
                    onPressed: () {
                      setState(() => _picking = true);
                      unawaited(_search());
                    },
                  ),
                  if (s.appId.isNotEmpty) ...[
                    const SizedBox(width: 6),
                    OfficeButton(
                      label: '✕',
                      tooltip: 'No Codemagic on this floor',
                      kind: BtnKind.danger,
                      onPressed: () => _pick(''),
                    ),
                  ],
                ],
              ],
            ),
            if (_picking) ...[
              const SizedBox(height: 6),
              BoxInput(
                key: const ValueKey('codemagic-search'),
                controller: _query,
                hint: '🔍 Its name on Codemagic',
                onChanged: (q) {
                  _debounce?.cancel();
                  _debounce = Timer(const Duration(milliseconds: 300), () => unawaited(_search(q)));
                },
              ),
              if (_error != null) Note('⚠️ $_error', top: 4, bad: true),
              if (_apps == null) const Padding(padding: EdgeInsets.all(8), child: Spinner()),
              for (final a in _apps ?? const <CodemagicApp>[])
                InkWell(
                  key: ValueKey('codemagic-app-${a.id}'),
                  onTap: () => _pick(a.id),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                    child: Text('📱 ${a.label}', style: heavy(13.5, weight: FontWeight.w700)),
                  ),
                ),
            ],
            const Note(
              'Builds of this floor\'s app: workers start them with agent-office codemagic build, and everyone can at the 🏗️ build tower.',
            ),
          ],
        ],
      );
    },
  );
}
