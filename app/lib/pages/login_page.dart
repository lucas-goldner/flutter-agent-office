// Sign in: the office password, or your own account once people have them (login.ts). The desktop
// app asks which office too (its Server field), and takes an invite link pasted there.

import 'package:flutter/material.dart';

import '../interop/browser.dart';
import '../net/api.dart';
import '../net/server.dart';
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

  /// The desktop app's office, e.g. http://localhost:4600.
  final _server = TextEditingController(text: desktopApp ? serverOrigin : '');

  /// Whether to ask for a name: once there are accounts. Optional while the shared password works.
  bool _askName = false;
  bool _shared = true;
  bool _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    documentTitle = 'Agent Office · Sign in';
    // A sign-in link from the office's terminal (/login#key=…): it works once, so take it out of the
    // address bar and trade it for a session. The key is after the #, so it never reaches a server log.
    final key = linkKey(locationHash);
    if (key != null) {
      replaceUrl(locationPath);
      _signInWithLink(key);
    }
    _load();
  }

  Future<void> _signInWithLink(String key) async {
    try {
      final r = await Api.postJson('/api/link', {'key': key});
      if (r.ok) return goTo('/');
      if (mounted) setState(() => _error = r.error('Could not sign in'));
    } catch (e) {
      if (mounted) setState(() => _error = desktopApp ? _unreachable(e) : 'Server unreachable');
    }
  }

  /// Focuses a field once it has been laid out (asking earlier throws on the web).
  void _focusLater(FocusNode node) => WidgetsBinding.instance.addPostFrameCallback((_) => node.requestFocus());

  /// Why the desktop app couldn't talk to the server, with the system's own reason (refused, no such
  /// host, not allowed), since "can't reach" alone doesn't say what to fix.
  String _unreachable(Object e) {
    final why = '$e'.replaceFirst(RegExp(r'^\w*Exception:\s*'), '').split('\n').first;
    return "Can't reach an office at $serverOrigin: $why";
  }

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
    } catch (e) {
      if (desktopApp && mounted) setState(() => _error = _unreachable(e));
      _focusLater(_passwordFocus);
    }
  }

  /// Takes the Server field (the desktop app): points the app at that office, or follows an invite
  /// (/join#…) or claim (/claim?t=…) link pasted there. False when there's nothing to sign in to here.
  bool _takeServer() {
    if (!desktopApp) return true;
    final text = _server.text.trim();
    final origin = normalizeServer(text);
    if (origin == null) {
      setState(() => _error = "That doesn't look like an office's address (like http://localhost:4600)");
      return false;
    }
    final changed = origin != serverOrigin;
    if (changed) setServerOrigin(origin);
    final link = Uri.tryParse(text.contains('://') ? text : 'http://$text');
    if (link != null &&
        ((link.path == '/join' && link.fragment.isNotEmpty) ||
            (link.path == '/claim' && (link.queryParameters['t'] ?? '').isNotEmpty))) {
      goTo('${link.path}${link.hasQuery ? '?${link.query}' : ''}${link.hasFragment ? '#${link.fragment}' : ''}');
      return false;
    }
    _server.text = origin;
    if (changed) {
      // Another office: ask it afresh whether it wants names.
      setState(() {
        _error = '';
        _askName = false;
        _shared = true;
      });
      _load();
    }
    return true;
  }

  Future<void> _submit() async {
    if (_busy) return;
    if (!_takeServer()) return;
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
    } catch (e) {
      setState(() => _error = desktopApp ? _unreachable(e) : 'Server unreachable');
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
      if (desktopApp) ...[
        LabeledField(
          label: 'Server',
          controller: _server,
          autofillHints: const [AutofillHints.url],
          onSubmitted: (_) {
            if (_takeServer()) _focusLater(_askName && _name.text.isEmpty ? _nameFocus : _passwordFocus);
          },
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(
            'The office to walk into. Got an invite link? Paste it here and press Enter.',
            style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
          ),
        ),
      ],
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

/// The one-time key in a sign-in link's fragment (#key=…), if it has one.
String? linkKey(String hash) {
  final k = Uri.splitQueryString(hash.startsWith('#') ? hash.substring(1) : hash)['key'];
  return k == null || k.isEmpty ? null : k;
}
