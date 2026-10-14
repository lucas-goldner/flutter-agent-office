// 🔐 Your sign-ins (ui/signins.ts): the Claude plan your workers run on and the GitHub account the office
// acts as for you, both your own (see the server's signins). The office runs the sign-in itself and hands you
// the page to open; or paste a token; admins may use the office machine's own instead.

import 'package:flutter/material.dart';
import 'package:office_shared/protocol.dart';

import '../interop/open_link.dart';
import '../office_scope.dart';
import '../state/store.dart' show Topic;
import 'modal.dart';
import 'prompt.dart' show confirmDialog;
import 'theme.dart';
import 'window_parts.dart';

const Map<SignInKind, String> _names = {SignInKind.claude: 'Claude', SignInKind.github: 'GitHub'};

({ModalHandle modal, ValueNotifier<String?> why})? _open;

/// Opens the window, or says [why] in the one that's open. [why] says what sent you here (hiring a worker
/// before signing in, say).
void openSignIns(OfficeScope scope, [String? why]) {
  final o = _open;
  if (o != null && !o.modal.closed) {
    o.why.value = why;
    return;
  }
  final banner = ValueNotifier<String?>(why);
  final modal = ModalStack.instance.show(
    (m) => _SignInsWindow(scope: scope, modal: m, why: banner),
    onClose: () => _open = null,
  );
  _open = (modal: modal, why: banner);
  scope.net.send(const SignInsGetCmd());
}

/// Whether the window should greet someone who just came in: their Claude sign-in still to do.
bool needsSigningIn(OfficeScope scope) {
  final s = scope.store.signins;
  return scope.store.me.account != null &&
      s != null &&
      s.claude.status == SignInStatus.none &&
      s.claude.how == SignInHow.login;
}

/// What greets someone who just joined with their sign-ins still to do.
const signInsWelcome =
    'Welcome! Sign in to Claude so the workers you hire run on your own plan, and to GitHub so what you do on the boards is yours.';

class _SignInsWindow extends StatefulWidget {
  const _SignInsWindow({required this.scope, required this.modal, required this.why});
  final OfficeScope scope;
  final ModalHandle modal;
  final ValueNotifier<String?> why;

  @override
  State<_SignInsWindow> createState() => _SignInsWindowState();
}

class _SignInsWindowState extends State<_SignInsWindow> with ListenTo {
  // Kept across renders, so a half-typed code or token survives the next update.
  final _code = TextEditingController();
  final _claude = TextEditingController();
  final _github = TextEditingController();

  @override
  void initState() {
    super.initState();
    listenTo(widget.scope.store.topics(const [Topic.signins, Topic.me]), () {
      final s = widget.scope.store.signins;
      // Once both are sorted, whatever sent you here is too.
      if (s != null && s.claude.status == SignInStatus.ok && s.github.status == SignInStatus.ok) {
        widget.why.value = null;
      }
      setState(() {});
    });
    listenTo(widget.why, () => setState(() {}));
  }

  @override
  void dispose() {
    _code.dispose();
    _claude.dispose();
    _github.dispose();
    super.dispose();
  }

  void _send(ClientMsg m) => widget.scope.net.send(m);

  @override
  Widget build(BuildContext context) {
    final store = widget.scope.store;
    final s = store.signins;
    final why = widget.why.value;
    return ModalWindow(
      modal: widget.modal,
      width: 640,
      title: const Text('🔐 Your sign-ins'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            'Your workers run on your own Claude plan, and the office acts on GitHub as you: comments, merges and pull requests show up under your name. Only your workers use them.',
            style: heavy(14, weight: FontWeight.w700),
          ),
          if (why != null) StatusBox(why, key: const ValueKey('signins-why')),
          const SizedBox(height: 12),
          if (s == null)
            Text(
              store.me.account != null
                  ? 'Loading…'
                  : 'On the shared office password, workers run on the office’s own sign-ins.',
              style: heavy(13, color: Swatch.muted),
            )
          else ...[
            _card(SignInKind.claude, s.claude, s.office),
            const SizedBox(height: 12),
            _card(SignInKind.github, s.github, s.office),
          ],
          Note(
            '',
            rich: [
              const TextSpan(text: 'Or open a 🐚 shell at any desk: it runs as you, so '),
              codeSpan('claude auth login'),
              const TextSpan(text: ' and '),
              codeSpan('gh auth login'),
              const TextSpan(text: ' typed there sign you in too.'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _row(TextEditingController c, String hint, String label, VoidCallback onSave, {bool secret = false}) => Row(
    children: [
      Expanded(
        child: Semantics(
          label: label,
          textField: true,
          child: BoxInput(controller: c, hint: hint, obscure: secret, onSubmitted: (_) => onSave()),
        ),
      ),
      const SizedBox(width: 8),
      OfficeButton(label: 'Save', onPressed: onSave),
    ],
  );

  Widget _card(SignInKind which, SignInState s, bool office) {
    final name = _names[which]!;
    final status = switch (s.status) {
      SignInStatus.ok => Text(
        '✅ ${s.how == SignInHow.office ? 'The office’s own${s.who != null ? ' (${s.who})' : ''}' : (s.who ?? 'Signed in')}',
        style: heavy(13, color: const Color(0xFF2B9348)),
      ),
      SignInStatus.busy => Text('⏳ Signing in…', style: heavy(13)),
      SignInStatus.none => Text('Not signed in', style: heavy(13, color: Swatch.muted)),
    };
    final body = <Widget>[
      if (s.error != null) StatusBox(s.error!, kind: StatusKind.error),
      ..._ways(which, name, s, office),
    ];
    return Container(
      key: ValueKey('signin-${which.wire}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Swatch.ink.withValues(alpha: 0.18), width: 2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(which == SignInKind.claude ? '✳️ Claude' : '🐙 GitHub', style: heavy(15))),
              status,
            ],
          ),
          const SizedBox(height: 8),
          ...body,
        ],
      ),
    );
  }

  List<Widget> _ways(SignInKind which, String name, SignInState s, bool office) {
    final pending = s.pending;
    if (pending != null) {
      final url = pending.url != null && pending.url!.startsWith('https://') ? pending.url : null;
      return [
        if (url == null)
          Note('Starting $name’s sign-in…', top: 0)
        else if (which == SignInKind.claude) ...[
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('1.', style: heavy(13)),
              OfficeButton(
                label: 'Open Claude’s sign-in page ↗',
                kind: BtnKind.primary,
                onPressed: () => openInNewTab(url),
              ),
              Text('and sign in with your own account.', style: heavy(13, weight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 8),
          Text('2. It shows you a code. Paste it here:', style: heavy(13, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: BoxInput(
                  key: const ValueKey('signin-code'),
                  controller: _code,
                  hint: 'Paste the code here',
                  onSubmitted: (_) => _sendCode(),
                ),
              ),
              const SizedBox(width: 8),
              OfficeButton(
                label: pending.sent == true ? 'Checking…' : 'Send',
                kind: BtnKind.primary,
                onPressed: pending.sent == true ? null : _sendCode,
              ),
            ],
          ),
        ] else ...[
          Text('1. Copy your one-time code:', style: heavy(13, weight: FontWeight.w700)),
          const SizedBox(height: 6),
          CommandBlock(pending.code ?? ''),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('2.', style: heavy(13)),
              OfficeButton(
                label: 'Open github.com/login/device ↗',
                kind: BtnKind.primary,
                onPressed: () => openInNewTab(url),
              ),
              Text('and enter it there.', style: heavy(13, weight: FontWeight.w700)),
            ],
          ),
          Note('3. This updates by itself once GitHub says yes.', top: 6),
        ],
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OfficeButton(label: 'Cancel', onPressed: () => _send(SignInsCancelCmd(which))),
        ),
      ];
    }
    if (s.status == SignInStatus.ok) {
      return [
        Align(
          alignment: Alignment.centerLeft,
          child: OfficeButton(
            label: s.how == SignInHow.office ? 'Use my own instead' : 'Sign out',
            onPressed: () {
              if (s.how == SignInHow.office) return _send(SignInsSignoutCmd(which));
              confirmDialog(
                'Sign out of $name?',
                which == SignInKind.claude
                    ? 'Workers you hire from now on need a new sign-in. The ones already running keep going.'
                    : 'The office stops acting on GitHub as you until you sign in again.',
                'Sign out',
                () => _send(SignInsSignoutCmd(which)),
              );
            },
          ),
        ),
      ];
    }
    // Not signed in (or busy looking): the ways in.
    final token = which == SignInKind.claude ? _claude : _github;
    void saveToken() {
      final t = token.text.trim();
      if (t.isEmpty) return;
      _send(SignInsTokenCmd(which, t));
      token.clear();
    }

    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          OfficeButton(
            key: ValueKey('signin-start-${which.wire}'),
            label: 'Sign in with $name',
            kind: BtnKind.primary,
            onPressed: () => _send(SignInsStartCmd(which)),
          ),
          if (office) OfficeButton(label: 'Use the office’s own', onPressed: () => _send(SignInsOfficeCmd(which))),
        ],
      ),
      if (which == SignInKind.claude)
        Note(
          '',
          rich: [
            const TextSpan(text: 'Or paste a token: run '),
            codeSpan('claude setup-token'),
            const TextSpan(text: ' on your own computer (or use an Anthropic API key).'),
          ],
        )
      else
        Note('Or paste a GitHub token (make one at github.com/settings/tokens with repo, read:org and workflow).'),
      const SizedBox(height: 6),
      _row(
        token,
        which == SignInKind.claude ? 'sk-ant-oat01-…' : 'ghp_… or github_pat_…',
        '$name token',
        saveToken,
        secret: true,
      ),
    ];
  }

  void _sendCode() {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    _send(SignInsCodeCmd(code));
    _code.clear();
  }
}
