// One-time password reveal: /claim?t=<token> (claim.ts). The server forgets the plaintext as soon
// as it answers, so the page warns before you leave until you've said you saved it.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interop/browser.dart';
import '../net/api.dart';
import '../ui/theme.dart';
import 'auth_card.dart';
import 'join_page.dart' show SignInLink;

class ClaimPage extends StatefulWidget {
  const ClaimPage({super.key});

  @override
  State<ClaimPage> createState() => _ClaimPageState();
}

class _ClaimPageState extends State<ClaimPage> {
  late final String _token;
  String _sub = 'Unlocking…';
  String? _password;
  bool _saved = false;
  bool _copied = false;
  String _error = '';
  void Function()? _unwarn;

  @override
  void initState() {
    super.initState();
    documentTitle = 'Agent Office · Your office is ready';
    _token = Uri.parse('http://x/$locationSearch').queryParameters['t'] ?? '';
    // Keep the single-use token out of the address bar and history.
    replaceUrl('/claim');
    _unwarn = warnBeforeUnload(() => _password != null && !_saved);
    _claim();
  }

  @override
  void dispose() {
    _unwarn?.call();
    super.dispose();
  }

  Future<void> _claim() async {
    if (_token.isEmpty) return _fail('This link is missing its claim token.');
    try {
      final r = await Api.postJson('/api/claim', {'token': _token});
      if (!r.ok) return _fail(r.error('Could not unlock the office.'));
      setState(() {
        _sub = 'One last thing before you walk in:';
        _password = '${r.body['password']}';
      });
    } catch (_) {
      _fail('Server unreachable.');
    }
  }

  void _fail(String msg) => setState(() {
    _sub = '';
    _error = msg;
  });

  @override
  Widget build(BuildContext context) => AuthCard(
    title: 'Your office is ready 🎉',
    sub: _sub.isEmpty ? null : Text(_sub),
    children: [
      if (_password != null) ...[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFFFFF3C4),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Swatch.ink, width: 2),
          ),
          child: Text.rich(
            TextSpan(
              style: heavy(13, weight: FontWeight.w700),
              children: const [
                TextSpan(text: 'Write this password down now. ', style: TextStyle(fontWeight: FontWeight.w900)),
                TextSpan(
                  text:
                      'It is shown this one time only — the office keeps just a hash and can never display it '
                      'again. Share it with teammates you invite.',
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: Swatch.ink, width: 2),
                ),
                child: SelectableText(_password!, style: const TextStyle(fontFamily: 'monospace', fontSize: 15)),
              ),
            ),
            const SizedBox(width: 8),
            OfficeButton(
              label: _copied ? 'Copied ✓' : 'Copy',
              dense: true,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: _password!));
                setState(() => _copied = true);
              },
            ),
          ],
        ),
        const SizedBox(height: 8),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          value: _saved,
          onChanged: (v) => setState(() => _saved = v ?? false),
          title: Text('I saved it somewhere safe', style: heavy(14)),
        ),
        WideButton('Enter the office', onPressed: _saved ? () => goReplace('/') : null),
      ],
      ErrorLine(_error),
      if (_error.isNotEmpty) const SignInLink(),
    ],
  );
}
