// 👥 Invite teammates: add someone's GitHub SSH keys so they can open a tunnel to the office, and
// the one command to send them (ui/team.ts).

import 'package:flutter/material.dart';

import '../office_scope.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'commands.dart';
import 'confirm.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

ModalHandle openTeam(OfficeScope scope) {
  final handle = ModalStack.instance.show((modal) => _TeamWindow(scope: scope, modal: modal));
  scope.net.send(const TeamGetCmd());
  return handle;
}

class _TeamWindow extends StatefulWidget {
  const _TeamWindow({required this.scope, required this.modal});
  final OfficeScope scope;
  final ModalHandle modal;

  @override
  State<_TeamWindow> createState() => _TeamWindowState();
}

class _TeamWindowState extends State<_TeamWindow> with ListenTo {
  Os _os = guessOs();
  (String, StatusKind)? _status;
  bool _inviting = false;
  final _input = TextEditingController();
  final _focus = FocusNode();

  Store get store => widget.scope.store;

  @override
  void initState() {
    super.initState();
    listenTo(store.topic(Topic.team), _changed);
    listenStream(widget.scope.net.messages, (msg) {
      if (msg is! TeamInvitedMsg) return;
      setState(() {
        _inviting = false;
        if (msg.error != null) {
          _status = (msg.error!, StatusKind.error);
          return;
        }
        _input.clear();
        final keys = msg.keys ?? 0;
        _status = (
          '✅ ${msg.name} is invited ($keys key${keys == 1 ? '' : 's'}). Send them the command below.',
          StatusKind.ok,
        );
      });
    });
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _invite() {
    final github = _input.text.trim();
    if (github.isEmpty) return _focus.requestFocus();
    setState(() {
      _inviting = true;
      _status = ("Fetching $github's keys from GitHub…", StatusKind.busy);
    });
    widget.scope.net.send(TeamInviteCmd(github));
  }

  @override
  Widget build(BuildContext context) {
    final t = store.team;
    return ModalWindow(
      modal: widget.modal,
      width: 680,
      title: const Text('👥 Invite teammates'),
      body: t == null
          ? Text(
              'Loading…',
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
            )
          : t.unavailable != null
          ? Text(t.unavailable!, style: heavy(16, weight: FontWeight.w700))
          : _body(t),
      footer: t == null || t.unavailable != null
          ? null
          : Row(
              children: [
                const FooterNote(
                  'Invited people still need to sign in: the office password, or an account from 🔑 Accounts.',
                ),
                const SizedBox(width: 8),
                CopyButton(
                  label: '✉️ Copy invite message',
                  kind: BtnKind.primary,
                  text: () => inviteMessage(t, _os, store.project?.name),
                ),
              ],
            ),
    );
  }

  Widget _body(TeamState t) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const FieldLabel('Invite someone by their GitHub username'),
      Row(
        children: [
          Expanded(
            child: BoxInput(
              controller: _input,
              focusNode: _focus,
              autofocus: true,
              maxLength: 40,
              hint: 'GitHub username',
              onSubmitted: (_) => _invite(),
            ),
          ),
          const SizedBox(width: 8),
          OfficeButton(label: 'Invite', kind: BtnKind.primary, onPressed: _inviting ? null : _invite),
        ],
      ),
      const Note(
        'Their SSH keys from github.com/<username>.keys can open a tunnel to this office — nothing else: no shell on the machine, no other ports.',
        top: 8,
      ),
      if (_status != null) StatusBox(_status!.$1, kind: _status!.$2),
      if (t.error != null) StatusBox(t.error!, kind: StatusKind.error),
      Padding(
        padding: const EdgeInsets.only(top: 18),
        child: Row(
          children: [
            Expanded(
              child: Text(
                'THEN SEND THEM THIS',
                style: heavy(14, weight: FontWeight.w900).copyWith(letterSpacing: 0.56),
              ),
            ),
            SegButtons<Os>(
              options: [for (final o in Os.values) (o, osLabel[o]!)],
              value: _os,
              onPick: (o) => setState(() => _os = o),
            ),
          ],
        ),
      ),
      CommandBlock(tunnelCommand(t, _os)),
      Note(
        '',
        top: 8,
        rich: [
          TextSpan(
            text:
                "It opens the tunnel and http://localhost:${t.port} in their browser. They keep the terminal open while they're in. ",
          ),
          if (t.fingerprint != null) ...[
            const TextSpan(text: 'The first time, ssh asks whether to trust the server: the fingerprint must be '),
            codeSpan(t.fingerprint!),
            const TextSpan(text: '.'),
          ],
        ],
      ),
      Note(
        '',
        top: 8,
        rich: [
          const TextSpan(text: "SSH only answers IP addresses you allowed. If theirs isn't, run "),
          codeSpan('deploy/aws.sh allow <their-ip>'),
          const TextSpan(text: ' (or '),
          codeSpan('allow anywhere'),
          const TextSpan(text: ') on your machine.'),
        ],
      ),
      SectionHeading('Invited', count: t.members.length),
      for (final m in t.members) _member(m),
      if (t.members.isEmpty)
        Text(
          'Nobody yet',
          style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
        ),
    ],
  );

  Widget _member(TeamMember m) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Expanded(child: Text(m.name, style: heavy(16))),
        Text(
          '${m.keys} key${m.keys == 1 ? '' : 's'}',
          style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
        ),
        const SizedBox(width: 10),
        SmallButton(
          label: 'Remove',
          tooltip: "Remove ${m.name}'s access",
          onPressed: () => confirmDialog(
            'Remove ${m.name}?',
            'Their keys stop working right away. Every open tunnel drops for a moment too (other teammates just re-run their command). ${m.name} still knows the office password.',
            'Remove',
            () => widget.scope.net.send(TeamRemoveCmd(m.name)),
          ),
        ),
      ],
    ),
  );
}
