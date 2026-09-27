// An invite link, /join#<token>: make your own account, then walk in (join.ts). The token rides in
// the fragment, so it never reaches a server log or a Referer header.

import 'package:flutter/material.dart';

import '../interop/browser.dart';
import '../net/api.dart';
import '../ui/theme.dart';
import 'auth_card.dart';
import 'login_page.dart' show kLoginNameKey;

class JoinPage extends StatefulWidget {
  const JoinPage({super.key});

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  final String _token = locationHash.startsWith('#') ? locationHash.substring(1) : locationHash;
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _again = TextEditingController();
  final _passwordFocus = FocusNode();
  final _againFocus = FocusNode();

  String _title = "You're invited 🎉";
  Widget _sub = const Text('Checking your invite…');
  bool _form = false;
  bool _nameLocked = false;
  bool _failed = false;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    documentTitle = 'Agent Office · Join';
    _peek();
  }

  void _fail(String msg) => setState(() {
    _sub = const SizedBox.shrink();
    _form = false;
    _error = msg;
    _failed = true;
  });

  Future<ApiResult> _post(Map<String, dynamic> body) => Api.postJson('/api/join', {'token': _token, ...body});

  Future<void> _peek() async {
    if (_token.isEmpty) {
      return _fail('This link is missing its invite code. Ask whoever sent it for the whole link.');
    }
    try {
      final r = await _post({'peek': true});
      if (!r.ok) return _fail(r.error('This invite link does not work.'));
      final invited = r.body['name'] as String?;
      final admin = r.body['role'] == 'admin';
      setState(() {
        _title = 'Join the ${r.body['project'] ?? 'office'} office';
        _sub = Text.rich(
          TextSpan(
            children: [
              TextSpan(text: '${r.body['by'] ?? 'Someone'} invited you${admin ? ' as an ' : '. '}'),
              if (admin) ...[
                const WidgetSpan(alignment: PlaceholderAlignment.middle, child: Pill('admin', color: Swatch.warn)),
                const TextSpan(text: '.'),
              ],
              const TextSpan(text: ' Make your own account to come in.'),
            ],
          ),
        );
        if (invited != null && invited.isNotEmpty) {
          _name.text = invited;
          _nameLocked = true;
        }
        _form = true;
      });
      if (_nameLocked) _passwordFocus.requestFocus();
    } catch (_) {
      _fail('Server unreachable.');
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    setState(() => _error = '');
    if (_password.text.length < 8) {
      setState(() => _error = 'At least 8 characters, please');
      _passwordFocus.requestFocus();
      return;
    }
    if (_password.text != _again.text) {
      setState(() => _error = "Those passwords don't match");
      _againFocus.requestFocus();
      return;
    }
    setState(() => _busy = true);
    try {
      final r = await _post({'name': _name.text.trim(), 'password': _password.text});
      if (!r.ok) {
        setState(() => _error = r.error('Could not make your account'));
        return;
      }
      storageSet(kLoginNameKey, '${r.body['name'] ?? _name.text.trim()}');
      goReplace('/');
    } catch (_) {
      setState(() => _error = 'Server unreachable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthCard(
    title: _title,
    sub: _sub,
    children: [
      if (_form) ...[
        LabeledField(
          label: 'Your name',
          controller: _name,
          readOnly: _nameLocked,
          autofocus: !_nameLocked,
          maxLength: 24,
          autofillHints: const [AutofillHints.username],
          onSubmitted: (_) => _passwordFocus.requestFocus(),
        ),
        LabeledField(
          label: 'Pick a password',
          controller: _password,
          focusNode: _passwordFocus,
          obscure: true,
          autofillHints: const [AutofillHints.newPassword],
          onSubmitted: (_) => _againFocus.requestFocus(),
        ),
        LabeledField(
          label: 'Once more',
          controller: _again,
          focusNode: _againFocus,
          obscure: true,
          autofillHints: const [AutofillHints.newPassword],
          onSubmitted: (_) => _submit(),
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            "At least 8 characters. It's yours alone: nobody else in the office ever sees it.",
            style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
          ),
        ),
        WideButton('Make my account', onPressed: _busy ? null : _submit),
      ],
      ErrorLine(_error),
      if (_failed) const _SignInLink(),
    ],
  );
}

class _SignInLink extends StatelessWidget {
  const _SignInLink({super.key});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: Center(
      child: TextButton(
        onPressed: () => goTo('/login'),
        child: Text('Go to sign in →', style: heavy(14, color: Swatch.accent)),
      ),
    ),
  );
}

/// The same link, for the claim page.
class SignInLink extends _SignInLink {
  const SignInLink({super.key});
}
