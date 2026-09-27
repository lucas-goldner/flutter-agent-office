// Send a prompt about an issue or PR to a worker: a new one at a free desk, or one already sitting
// at a desk (it lands in their input box, queued if they're busy). A port of ui/ask.ts.

import 'package:flutter/material.dart';

import '../office_scope.dart';
import '../shared/protocol.dart';
import '../world/laptop_screen.dart' show kTermFont, kTermFontFallback;
import 'child_button.dart';
import 'modal.dart';
import 'prompt.dart';
import 'provider.dart';
import 'theme.dart';
import 'worker_text.dart';

class AskWorker {
  const AskWorker({required this.id, required this.name, required this.color, required this.status});

  final String id;
  final String name;
  final String color;
  final WorkerStatus status;
}

class AskOptions {
  const AskOptions({
    required this.title,
    this.context,
    this.initial,
    this.placeholder,
    this.newDesk,
    required this.workers,
    required this.worktreeOption,
    this.providerOption = false,
    required this.onSubmit,
  });

  final String title;

  /// Told to the worker before your text, so it knows what you mean. Shown, not editable.
  final String? context;

  /// A ready-made prompt to start from.
  final String? initial;
  final String? placeholder;

  /// The desk a new worker would take, when one is free.
  final String? newDesk;
  final List<AskWorker> workers;

  /// Offer the "own git worktree" option for a new worker.
  final bool worktreeOption;

  /// Offer the configured provider choice for a new worker.
  final bool providerOption;

  /// `to` is a worker id, or null for a new worker.
  final void Function(String prompt, String? to, bool worktree, AgentProvider? provider, String? model) onSubmit;
}

ModalHandle openAsk(OfficeScope scope, AskOptions opts) =>
    ModalStack.instance.show((m) => _AskWindow(modal: m, opts: opts, project: scope.store.project));

class _AskWindow extends StatefulWidget {
  const _AskWindow({required this.modal, required this.opts, required this.project});

  final ModalHandle modal;
  final AskOptions opts;
  final ProjectInfo? project;

  @override
  State<_AskWindow> createState() => _AskWindowState();
}

class _AskWindowState extends State<_AskWindow> {
  late String? _to = widget.opts.newDesk != null ? null : widget.opts.workers.firstOrNull?.id;
  late final _text = TextEditingController(text: widget.opts.initial ?? '');
  final _focus = FocusNode();
  // Shared with the hire prompt, so the choice sticks either way.
  late bool _worktree = worktreePref();
  late final ProviderPickerController? _provider = widget.opts.providerOption ? ProviderPickerController(widget.project) : null;
  bool _contextOpen = false;

  @override
  void initState() {
    super.initState();
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
    if (text.isEmpty) {
      _focus.requestFocus();
      return;
    }
    final p = _provider;
    if (_to == null && p != null && !p.valid()) return;
    widget.modal.close();
    if (_to == null && o.worktreeOption) saveWorktreePref(_worktree);
    o.onSubmit(
      o.context != null ? '${o.context}\n\n$text' : text,
      _to,
      _to == null && o.worktreeOption && _worktree,
      _to == null ? p?.value() : null,
      _to == null ? p?.model() : null,
    );
  }

  @override
  Widget build(BuildContext context) {
    final o = widget.opts;
    final label = heavy(14);
    return ModalWindow(
      modal: widget.modal,
      width: 660,
      title: Text(o.title),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('Send to', style: label),
          ),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              if (o.newDesk != null)
                ChildButton(
                  kind: _to == null ? BtnKind.on : BtnKind.plain,
                  onPressed: () => setState(() => _to = null),
                  child: Text('✨ New worker · ${o.newDesk}'),
                ),
              for (final w in o.workers)
                ChildButton(
                  kind: _to == w.id ? BtnKind.on : BtnKind.plain,
                  tooltip: "Type it into ${w.name}'s prompt",
                  onPressed: () => setState(() => _to = w.id),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    spacing: 6,
                    children: [
                      Dot(hexColor(w.color), size: 10),
                      Text(w.name),
                      Opacity(
                        opacity: 0.75,
                        child: Text(statusLabel(w.status), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          if (o.context != null) _context(o.context!),
          Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Text('Prompt', style: label),
          ),
          PromptField(
            controller: _text,
            focusNode: _focus,
            onSend: _send,
            hint: o.placeholder ?? 'What should the worker do?',
            minLines: o.initial != null ? 9 : 5,
            maxLines: 14,
          ),
          if (_provider != null && _to == null) ProviderPicker(controller: _provider),
          if (_to == null && o.worktreeOption)
            WorktreeToggle(
              value: _worktree,
              onChanged: (v) => setState(() => _worktree = v),
              tooltip: 'Isolate the new worker on its own branch so parallel workers never collide',
            ),
        ],
      ),
      footer: Row(
        spacing: 8,
        children: [
          const FooterNote('Enter to send · Shift+Enter for a new line'),
          OfficeButton(label: 'Cancel', onPressed: widget.modal.close),
          OfficeButton(label: _to != null ? 'Send ✨' : 'Hire & start', kind: BtnKind.primary, onPressed: _send),
        ],
      ),
    );
  }

  /// details.ask-context: what the worker is told first, folded away.
  Widget _context(String text) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () => setState(() => _contextOpen = !_contextOpen),
            child: Text('${_contextOpen ? '▾' : '▸'} The worker is told first…', style: heavy(13, color: Swatch.muted)),
          ),
        ),
        if (_contextOpen)
          Container(
            margin: const EdgeInsets.only(top: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Swatch.paper2,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0x332B2D42), width: 2),
            ),
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: kTermFont, fontFamilyFallback: kTermFontFallback, fontSize: 12, height: 1.5, color: Swatch.ink),
            ),
          ),
      ],
    ),
  );
}
