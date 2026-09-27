// Agent Office in the browser. The office server serves this one app at /, /login, /join and
// /claim; the path picks the page.

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'interop/browser.dart';
import 'net/api.dart';
import 'office_page.dart';
import 'pages/claim_page.dart';
import 'pages/join_page.dart';
import 'pages/login_page.dart';
import 'ui/theme.dart';

void main() {
  startupQuery; // read the query before the router rewrites the address
  usePathUrlStrategy();
  runApp(const AgentOfficeApp());
}

class AgentOfficeApp extends StatelessWidget {
  const AgentOfficeApp({super.key});

  @override
  Widget build(BuildContext context) {
    final path = locationPath.replaceAll(RegExp(r'\.html$'), '');
    final Widget home = switch (path) {
      '/login' => const LoginPage(),
      '/join' => const JoinPage(),
      '/claim' => const ClaimPage(),
      _ => const _SignedIn(child: OfficePage()),
    };
    return MaterialApp(
      title: 'Agent Office',
      debugShowCheckedModeBanner: false,
      theme: officeTheme(),
      home: home,
    );
  }
}

/// Checks the session before the office loads: signed out goes to /login, as the old main.ts did.
class _SignedIn extends StatefulWidget {
  const _SignedIn({required this.child});
  final Widget child;

  @override
  State<_SignedIn> createState() => _SignedInState();
}

class _SignedInState extends State<_SignedIn> {
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    Api.whoami().then((me) {
      if (me == null) return goReplace('/login');
      if (mounted) setState(() => _ok = true);
    }).catchError((_) {
      if (mounted) setState(() => _ok = true);
    });
  }

  @override
  Widget build(BuildContext context) => _ok ? widget.child : const ColoredBox(color: Swatch.sky);
}
