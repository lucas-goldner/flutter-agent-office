// Sign in: the office password, or your own account once people have them (login.ts).

import 'package:flutter/material.dart';

import '../interop/browser.dart';
import '../net/api.dart';
import '../ui/theme.dart';
import 'auth_card.dart';

const kLoginNameKey = 'agent-office.login-name';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final _name = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();
  final _nameFocus = FocusNode();

  /// Whether to ask for a name: once there are accounts. Optional while the shared password works.
  bool _askName = false;
  bool _shared = true;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    documentTitle = 'Agent Office · Sign in';
    _load();
  }

  /// Focuses a field once it has been laid out (asking earlier throws on the web).
  void _focusLater(FocusNode node) => WidgetsBinding.instance.addPostFrameCallback((_) => node.requestFocus());

  Future<void> _load() async {
    try {
      final r = await Api.getJson('/api/login');
      final accounts = r.body['accounts'] == true;
      final shared = r.body['shared'] != false;
      if (!accounts && shared) return _focusLater(_passwordFocus);
      setState(() {
        _askName = true;
        _shared = shared;
        _name.text = storageGet(kLoginNameKey) ?? '';
      });
      _focusLater(_name.text.isEmpty ? _nameFocus : _passwordFocus);
    } catch (_) {
      _focusLater(_passwordFocus);
    }
  }

  Future<void> _submit() async {
    if (_busy) return;
    final name = _askName ? _name.text.trim() : '';
    if (_askName && !_shared && name.isEmpty) {
      setState(() => _error = 'Your name, please');
      _nameFocus.requestFocus();
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final r = await Api.postJson('/api/login', {'name': name, 'password': _password.text});
      if (r.ok) {
        storageSet(kLoginNameKey, name);
        goTo('/');
        return;
      }
      setState(() => _error = r.error('Could not sign in'));
      _password.selection = TextSelection(baseOffset: 0, extentOffset: _password.text.length);
      _passwordFocus.requestFocus();
    } catch (_) {
      setState(() => _error = 'Server unreachable');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AuthCard(
    title: 'Agent Office',
    sub: Text(
      !_askName
          ? "Knock knock. What's the password?"
          : _shared
          ? 'Knock knock. Who is it?'
          : 'Knock knock. Who is it? Sign in with your own account.',
    ),
    children: [
      if (_askName)
        LabeledField(
          label: 'Your name',
          controller: _name,
          focusNode: _nameFocus,
          maxLength: 24,
          autofillHints: const [AutofillHints.username],
          onSubmitted: (_) => _passwordFocus.requestFocus(),
        ),
      LabeledField(
        label: 'Password',
        controller: _password,
        focusNode: _passwordFocus,
        obscure: true,
        autofillHints: const [AutofillHints.password],
        onSubmitted: (_) => _submit(),
      ),
      if (_askName && _shared)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            'Came in with the shared office password? Leave your name blank.',
            style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
          ),
        ),
      WideButton('Come on in', onPressed: _busy ? null : _submit),
      ErrorLine(_error),
    ],
  );
}
