// The prompt box (hire a worker, commit, open a PR…), the "are you sure?" dialog, and sending a
// worker with its own worktree home: a port of ui/prompt.ts.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interop/portable.dart';
import '../office_scope.dart';

import 'package:office_shared/protocol.dart';

import 'child_button.dart';
import 'modal.dart';
import 'prompt_logic.dart';
import 'provider.dart';
import 'theme.dart';

/// What came with the text: the worktree box and the provider picker, when they were offered.
typedef PromptChoice = ({bool worktree, AgentProvider? provider, String? model, AgentEffort? effort});

class PromptOptions {
  const PromptOptions({
    required this.title,
    this.subtitle,
    this.warning,
    this.placeholder,
    this.initial,
    this.submitLabel,
    this.allowEmpty = false,
    this.worktreeOption = false,
    this.providerOption = false,
    this.project,
    this.office,
    required this.onSubmit,
  });

  final String title;
  final String? subtitle;

  /// A warning over the prompt, e.g. that the machine is under pressure.
  final String? warning;
  final String? placeholder;
  final String? initial;
  final String? submitLabel;

  /// Allow hiring a worker without an initial prompt (the direct hire flow).
  final bool allowEmpty;

  /// Offer the "own git worktree" option (only when hiring a new worker).
  final bool worktreeOption;

  /// Offer the configured agent provider choice (only when hiring a new worker); needs [project].
  final bool providerOption;
  final ProjectInfo? project;

  /// The office's default worker as picked in ⚙️ Settings (store.prompts.agent).
  final PromptsAgent? office;
  final void Function(String text, PromptChoice opts) onSubmit;
}

const _wtKey = 'agent-office.worktree';
bool worktreePref() => storageGet(_wtKey) == '1';
void saveWorktreePref(bool on) => storageSet(_wtKey, on ? '1' : '0');

ModalHandle openPrompt(PromptOptions opts) => ModalStack.instance.show((m) => _PromptWindow(modal: m, opts: opts));

class _PromptWindow extends StatefulWidget {
  const _PromptWindow({required this.modal, required this.opts});

  final ModalHandle modal;
  final PromptOptions opts;

  @override
  State<_PromptWindow> createState() => _PromptWindowState();
}

class _PromptWindowState extends State<_PromptWindow> {
  late final _text = TextEditingController(text: widget.opts.initial ?? '');
  final _focus = FocusNode();
  late bool _worktree = worktreePref();
  late final ProviderPickerController? _provider = widget.opts.providerOption
      ? ProviderPickerController(widget.opts.project, office: widget.opts.office)
      : null;

  @override
  void initState() {
    super.initState();
    // The caret at the end, like setSelectionRange(len, len).
    _text.selection = TextSelection.collapsed(offset: _text.text.length);
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    _provider?.dispose();
    super.dispose();
  }

  void _send() {
    final o = widget.opts;
    final text = _text.text.trim();
    if (text.isEmpty && !o.allowEmpty) {
      _focus.requestFocus();
      return;
    }
    final p = _provider;
    if (p != null && !p.valid()) return;
    widget.modal.close();
    if (o.worktreeOption) saveWorktreePref(_worktree);
    o.onSubmit(text, (
      worktree: o.worktreeOption && _worktree,
      provider: p?.value(),
      model: p?.model(),
      effort: p?.effort(),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.opts;
    return ModalWindow(
      modal: widget.modal,
      title: Text(o.title),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (o.warning != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                o.warning!,
                style: heavy(14, color: Swatch.bad, weight: FontWeight.w800),
              ),
            ),
          if (o.subtitle != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Text(
                o.subtitle!,
                style: heavy(14, color: Swatch.muted, weight: FontWeight.w700),
              ),
            ),
          PromptField(
            controller: _text,
            focusNode: _focus,
            onSend: _send,
            hint: o.placeholder ?? 'What should the worker work on?',
            minLines: 7,
          ),
          if (_provider != null) ProviderPicker(controller: _provider),
          if (o.worktreeOption)
            WorktreeToggle(
              value: _worktree,
              onChanged: (v) => setState(() => _worktree = v),
              tooltip: 'Isolate this worker on its own branch so parallel workers never collide',
            ),
        ],
      ),
      footer: Row(
        spacing: 8,
        children: [
          const FooterNote('Enter to send · Shift+Enter for a new line'),
          OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
          OfficeButton(label: o.submitLabel ?? 'Send ✨', kind: BtnKind.primary, onPressed: _send),
        ],
      ),
    );
  }
}

/// '🌿 Work in its own git worktree & branch', a checkbox row.
class WorktreeToggle extends StatelessWidget {
  const WorktreeToggle({super.key, required this.value, required this.onChanged, required this.tooltip});

  final bool value;
  final ValueChanged<bool> onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 10),
    child: Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 8,
          children: [
            SizedBox(
              width: 18,
              height: 18,
              child: Checkbox(
                value: value,
                onChanged: (v) => onChanged(v ?? false),
                activeColor: Swatch.accent,
                side: const BorderSide(color: Swatch.ink, width: 2),
              ),
            ),
            Text('🌿 Work in its own git worktree & branch', style: heavy(14, weight: FontWeight.w700)),
          ],
        ),
      ),
    ),
  );
}

/// "Are you sure?": [confirmLabel] in red does it, 'Never mind' doesn't. Enter confirms.
ModalHandle confirmDialog(String title, String body, String confirmLabel, VoidCallback onConfirm) {
  late final ModalHandle modal;
  void yes() {
    modal.close();
    onConfirm();
  }

  modal = ModalStack.instance.show(
    (m) => CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter): yes},
      child: Focus(
        autofocus: true,
        child: ModalWindow(
          modal: m,
          title: Text(title),
          body: Text(body, style: heavy(14, weight: FontWeight.w700)),
          footer: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              OfficeButton(label: 'Never mind', onPressed: m.close),
              OfficeButton(label: confirmLabel, kind: BtnKind.danger, onPressed: yes),
            ],
          ),
        ),
      ),
    ),
  );
  return modal;
}

class SendHomeOptions {
  const SendHomeOptions({
    required this.workerId,
    required this.name,
    required this.where,
    required this.worktree,
    required this.onConfirm,
    this.ask,
  });

  final String workerId;
  final String name;

  /// The desk's label.
  final String where;
  final ({String path, String branch}) worktree;

  /// Asks the office what the worktree holds (default: a worker.worktree message); the answer comes
  /// back as a WorkerWorktreeMsg.
  final VoidCallback? ask;
  final void Function(WorktreeCleanup cleanup) onConfirm;
}

/// Asks what a worker's worktree holds; gives up after 8 seconds.
Future<WorktreeState> _inspectWorktree(OfficeScope scope, String workerId, VoidCallback ask) {
  final done = Completer<WorktreeState>();
  late final StreamSubscription<ServerMsg> sub;
  final timer = Timer(const Duration(seconds: 8), () {
    sub.cancel();
    if (!done.isCompleted) {
      done.complete(
        const WorktreeState(exists: true, dirty: 0, ahead: 0, unpushed: 0, error: 'the office did not answer'),
      );
    }
  });
  sub = scope.net.messages.listen((m) {
    if (m is WorkerWorktreeMsg && m.workerId == workerId && !done.isCompleted) {
      timer.cancel();
      sub.cancel();
      done.complete(m.state);
    }
  });
  ask();
  return done.future;
}

/// Sending home a worker that has its own worktree: pick what becomes of the worktree and its branch.
/// Opens on "keep" while the office checks the worktree, then suggests deleting when nothing would be lost.
ModalHandle sendHomeDialog(OfficeScope scope, SendHomeOptions opts) => ModalStack.instance.show(
  (m) => _SendHome(
    modal: m,
    opts: opts,
    check: _inspectWorktree(scope, opts.workerId, opts.ask ?? () => scope.net.send(WorkerWorktreeCmd(opts.workerId))),
  ),
);

class _SendHome extends StatefulWidget {
  const _SendHome({required this.modal, required this.opts, required this.check});

  final ModalHandle modal;
  final SendHomeOptions opts;
  final Future<WorktreeState> check;

  @override
  State<_SendHome> createState() => _SendHomeState();
}

class _SendHomeState extends State<_SendHome> {
  WorktreeCleanup _choice = WorktreeCleanup.keep;
  bool _touched = false;
  ({List<String> lines, bool risky})? _report;

  @override
  void initState() {
    super.initState();
    widget.check.then((s) {
      if (!mounted) return;
      setState(() {
        _report = worktreeReport(s, widget.opts.worktree.branch);
        if (!_touched) _choice = _report!.risky ? WorktreeCleanup.keep : WorktreeCleanup.all;
      });
    });
  }

  void _submit() {
    widget.modal.close();
    widget.opts.onConfirm(_choice);
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.opts;
    final (:path, :branch) = o.worktree;
    final report = _report;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter): _submit},
      child: Focus(
        autofocus: true,
        child: ModalWindow(
          modal: widget.modal,
          title: Text('Send ${o.name} home?'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  'This stops the session at ${o.where} for everyone and frees the desk. ${o.name} worked in its own worktree on 🌿 $branch:',
                  style: heavy(14, weight: FontWeight.w700),
                ),
              ),
              for (final (value, title, sub) in cleanupChoices(path, branch))
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _Choice(
                    title: title,
                    sub: sub,
                    on: _choice == value,
                    onTap: () => setState(() {
                      _touched = true;
                      _choice = value;
                    }),
                  ),
                ),
              _WtStatus(lines: report?.lines ?? ['Checking what $branch holds…'], warn: report?.risky ?? false),
            ],
          ),
          footer: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 8,
            children: [
              OfficeButton(label: 'Never mind', onPressed: widget.modal.close),
              OfficeButton(label: kCleanupLabel[_choice]!, kind: BtnKind.danger, onPressed: _submit),
            ],
          ),
        ),
      ),
    );
  }
}

/// A label.choice: a radio with a title and a line under it; accent border when picked.
class _Choice extends StatelessWidget {
  const _Choice({required this.title, required this.sub, required this.on, required this.onTap});

  final String title;
  final String sub;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => MouseRegion(
    cursor: SystemMouseCursors.click,
    child: GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: on ? Swatch.paper2 : Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: on ? Swatch.accent : Swatch.ink, width: kBorder),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                on ? Icons.radio_button_checked : Icons.radio_button_off,
                size: 16,
                color: on ? Swatch.accent : Swatch.ink,
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: heavy(14)),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      sub,
                      style: heavy(12, color: Swatch.muted, weight: FontWeight.w600).copyWith(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// The p.wt-status line under the choices; boxed in yellow when deleting would lose work.
class _WtStatus extends StatelessWidget {
  const _WtStatus({required this.lines, required this.warn});

  final List<String> lines;
  final bool warn;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      lines.join('\n'),
      style: heavy(13, color: warn ? Swatch.ink : Swatch.muted, weight: FontWeight.w700).copyWith(height: 1.45),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: warn
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFFFF3C4),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Swatch.ink, width: 2),
              ),
              child: text,
            )
          : text,
    );
  }
}
