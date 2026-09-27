// 🔑 Accounts, for admins: invite people by link, list them, change their role or revoke them,
// and the shared office password (ui/accounts.ts).

import 'package:flutter/material.dart';

import '../office_scope.dart';
import 'package:office_shared/protocol.dart';
import '../state/store.dart';
import 'commands.dart';
import 'confirm.dart';
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

String get _origin => Uri.base.origin;

ModalHandle openAccounts(OfficeScope scope) {
  final handle = ModalStack.instance.show((modal) => _AccountsWindow(scope: scope, modal: modal));
  scope.net.send(const AccountsGetCmd());
  return handle;
}

class _AccountsWindow extends StatefulWidget {
  const _AccountsWindow({required this.scope, required this.modal});
  final OfficeScope scope;
  final ModalHandle modal;

  @override
  State<_AccountsWindow> createState() => _AccountsWindowState();
}

class _AccountsWindowState extends State<_AccountsWindow> with ListenTo {
  (String, StatusKind)? _status;

  /// The invite just made, shown big until the next one.
  AccountInvite? _fresh;
  bool _inviting = false;
  AccountRole _role = AccountRole.member;
  final _name = TextEditingController();

  Store get store => widget.scope.store;

  void _send(ClientMsg m) => widget.scope.net.send(m);

  @override
  void initState() {
    super.initState();
    listenTo(store.topic(Topic.accounts), _changed);
    // No longer an admin (someone changed your role): the list isn't yours to see any more.
    listenTo(store.topic(Topic.me), () => store.me.admin ? _changed() : widget.modal.close());
    listenStream(widget.scope.net.messages, (msg) {
      if (msg is! AccountsInvitedMsg) return;
      setState(() {
        _inviting = false;
        final invite = msg.invite;
        if (msg.error != null || invite == null) {
          _status = (msg.error ?? 'Could not make the invite', StatusKind.error);
          return;
        }
        _fresh = invite;
        _name.clear();
        _status = (
          '✅ Send this link to ${invite.name ?? 'them'}. It works once and expires after 7 days.',
          StatusKind.ok,
        );
      });
    });
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _invite() {
    setState(() => _inviting = true);
    final name = _name.text.trim();
    _send(AccountsInviteCmd(name: name.isEmpty ? null : name, role: _role));
  }

  @override
  Widget build(BuildContext context) {
    final s = store.accounts;
    final me = store.me;
    return ModalWindow(
      modal: widget.modal,
      width: 680,
      title: const Text('🔑 Accounts'),
      body: s == null
          ? Text(
              'Loading…',
              style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
            )
          : _body(s, me),
      footer: Row(
        children: [
          FooterNote(
            me.account != null
                ? "You're signed in as ${me.account!.name} (${me.account!.role.wire})."
                : "You're signed in with the shared office password.",
          ),
        ],
      ),
    );
  }

  Widget _body(AccountsState s, Me me) {
    final canSwitchOff = me.account?.role == AccountRole.admin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const FieldLabel('Invite someone'),
        Row(
          children: [
            Expanded(
              child: BoxInput(
                controller: _name,
                autofocus: true,
                maxLength: 24,
                hint: 'Their name (optional)',
                onSubmitted: (_) => _invite(),
              ),
            ),
            const SizedBox(width: 8),
            _RoleSelect(value: _role, onChanged: (r) => setState(() => _role = r)),
            const SizedBox(width: 8),
            OfficeButton(label: 'Make invite link', kind: BtnKind.primary, onPressed: _inviting ? null : _invite),
          ],
        ),
        const Note(
          'You get a link that makes one account, with its own name and password. It works once and expires after 7 days. Leave the name empty and they pick their own.',
          top: 8,
        ),
        if (_status != null) StatusBox(_status!.$1, kind: _status!.$2),
        if (_fresh != null) CommandBlock(inviteLink(_fresh!, _origin), top: 10),
        if (store.invites)
          const Note('On this office they also need a way in: add their GitHub keys under 👥 Invite.', top: 8),
        SectionHeading('People', count: s.accounts.length),
        for (final a in s.accounts) _account(a, s, me),
        if (s.accounts.isEmpty)
          Text(
            'Nobody has an account yet',
            style: heavy(13, color: Swatch.muted, weight: FontWeight.w600),
          ),
        if (s.invites.isNotEmpty) ...[
          SectionHeading('Open invites', count: s.invites.length),
          for (final v in s.invites) _invitation(v),
        ],
        // The shared password: the old way in, kept as a fallback until everyone has an account.
        Padding(
          padding: const EdgeInsets.only(top: 18),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'SHARED OFFICE PASSWORD',
                  style: heavy(14, weight: FontWeight.w900).copyWith(letterSpacing: 0.56),
                ),
              ),
              SmallButton(
                label: s.sharedPassword ? 'Switch it off' : 'Switch it back on',
                kind: s.sharedPassword ? BtnKind.danger : BtnKind.plain,
                onPressed: s.sharedPassword && !canSwitchOff
                    ? null
                    : () {
                        if (!s.sharedPassword) return _send(const AccountsSharedCmd(true));
                        confirmDialog(
                          'Switch off the shared password?',
                          'From now on only people with an account of their own can sign in. Everyone who came in with the shared password is signed out right away.',
                          'Switch it off',
                          () => _send(const AccountsSharedCmd(false)),
                        );
                      },
              ),
            ],
          ),
        ),
        Note(
          '',
          top: 8,
          rich: [
            TextSpan(
              text: s.sharedPassword
                  ? 'On. Anyone who knows it gets in as an admin and picks any name they like. Once everyone has an account, switch it off, so that revoking someone really locks them out.'
                  : 'Off: only accounts can sign in. If every admin is ever locked out, run agent-office accounts password on on the office’s machine.',
            ),
            if (s.sharedPassword && !canSwitchOff)
              const TextSpan(
                text: ' Make yourself an admin account and sign in with it before you switch it off.',
                style: TextStyle(fontWeight: FontWeight.w900),
              ),
          ],
        ),
      ],
    );
  }

  Widget _account(AccountInfo a, AccountsState s, Me me) {
    final you = me.account?.name == a.name;
    final seen = a.online
        ? 'in the office'
        : a.lastSeenAt != null
        ? 'seen ${timeAgo(a.lastSeenAt!)}'
        : 'never came in';
    final admin = a.role == AccountRole.admin;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Tooltip(message: seen, child: Dot(a.online ? Swatch.good : const Color(0xFFDEE2E6))),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(text: a.name),
                  if (you)
                    TextSpan(
                      text: ' (you)',
                      style: heavy(16, color: Swatch.muted, weight: FontWeight.w600),
                    ),
                ],
              ),
              style: heavy(16),
            ),
          ),
          _RolePill(a.role),
          const SizedBox(width: 10),
          Tooltip(
            message: 'Invited by ${a.createdBy}',
            child: Text(
              seen,
              style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
            ),
          ),
          if (!you) ...[
            const SizedBox(width: 10),
            SmallButton(
              label: admin ? 'Make member' : 'Make admin',
              tooltip: admin ? 'Take away admin rights' : 'Let them manage accounts too',
              onPressed: () => _send(AccountsRoleCmd(a.id, admin ? AccountRole.member : AccountRole.admin)),
            ),
            const SizedBox(width: 10),
            SmallButton(
              label: 'Revoke',
              kind: BtnKind.danger,
              tooltip: "Delete ${a.name}'s account",
              onPressed: () => confirmDialog(
                'Revoke ${a.name}?',
                "Their account is deleted and they're signed out everywhere right away. Terminals they typed in keep running. ${s.sharedPassword ? 'If ${a.name} also knows the shared office password, they can still use that: switch it off below.' : ''}",
                'Revoke',
                () => _send(AccountsRevokeCmd(a.id)),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _invitation(AccountInvite v) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Row(
      children: [
        Expanded(
          child: v.name != null
              ? Text(v.name!, style: heavy(16))
              : Text('they pick a name', style: heavy(16).copyWith(fontStyle: FontStyle.italic)),
        ),
        _RolePill(v.role),
        const SizedBox(width: 10),
        Tooltip(
          message: 'Made by ${v.createdBy} ${timeAgo(v.createdAt)}',
          child: Text(
            expiresIn(v.expiresAt),
            style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
          ),
        ),
        const SizedBox(width: 10),
        CopyButton(label: 'Copy link', dense: true, text: () => inviteLink(v, _origin)),
        const SizedBox(width: 10),
        SmallButton(
          label: 'Cancel',
          tooltip: 'The link stops working',
          onPressed: () {
            if (_fresh?.id == v.id) setState(() => _fresh = null);
            _send(AccountsCancelCmd(v.id));
          },
        ),
      ],
    ),
  );
}

/// .role: a pill, yellow for admins.
class _RolePill extends StatelessWidget {
  const _RolePill(this.role);
  final AccountRole role;

  @override
  Widget build(BuildContext context) =>
      Pill(role.wire, color: role == AccountRole.admin ? Swatch.warn : const Color(0xFFE0F2FE));
}

/// The Member / Admin select.
class _RoleSelect extends StatelessWidget {
  const _RoleSelect({required this.value, required this.onChanged});
  final AccountRole value;
  final ValueChanged<AccountRole> onChanged;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Swatch.ink, width: kBorder),
    ),
    child: DropdownButtonHideUnderline(
      child: DropdownButton<AccountRole>(
        value: value,
        style: heavy(15),
        borderRadius: BorderRadius.circular(12),
        focusColor: Colors.transparent,
        items: const [
          DropdownMenuItem(value: AccountRole.member, child: Text('Member')),
          DropdownMenuItem(value: AccountRole.admin, child: Text('Admin')),
        ],
        onChanged: (r) => r == null ? null : onChanged(r),
      ),
    ),
  );
}
