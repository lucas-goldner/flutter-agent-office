// Agent Office in the browser. The office server serves this one app at /, /login, /join and
// /claim; the path picks the page. The desktop app (macOS) has no address bar: the same paths are
// an in-app route (interop/browser_io.dart), and it starts at the office when it still has a
// session for it, at the sign-in page otherwise.

import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart';

import 'interop/browser.dart';
import 'net/api.dart';
import 'net/server.dart';
import 'office_page.dart';
import 'pages/claim_page.dart';
import 'pages/join_page.dart';
import 'pages/login_page.dart';
import 'ui/modal.dart';
import 'ui/theme.dart';

void main() {
  initPlatform(); // the web reads the query before the router rewrites the address; the app its storage
  usePathUrlStrategy();
  if (desktopApp && sessionCookie != null) goReplace('/');
  runApp(const AgentOfficeApp());
}

class AgentOfficeApp extends StatelessWidget {
  const AgentOfficeApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Agent Office',
    debugShowCheckedModeBanner: false,
    theme: officeTheme(),
    home: navigation == null ? _page() : const _Routed(),
  );
}

/// The page for the current path.
Widget _page() {
  final path = locationPath.replaceAll(RegExp(r'\.html$'), '');
  return switch (path) {
    '/login' => const LoginPage(),
    '/join' => const JoinPage(),
    '/claim' => const ClaimPage(),
    _ => const _SignedIn(child: OfficePage()),
  };
}

/// The desktop app's pages: rebuilt whenever the in-app route changes (or the page "reloads").
class _Routed extends StatefulWidget {
  const _Routed();

  @override
  State<_Routed> createState() => _RoutedState();
}

class _RoutedState extends State<_Routed> {
  @override
  void initState() {
    super.initState();
    navigation!.addListener(_changed);
  }

  @override
  void dispose() {
    navigation!.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    // Windows live in the app's overlay, above the page: they'd outlive the office otherwise.
    ModalStack.instance.closeAll();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => KeyedSubtree(key: ValueKey(pageKey), child: _page());
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
    Api.whoami()
        .then((me) {
          if (me == null) return goReplace('/login');
          if (mounted) setState(() => _ok = true);
        })
        .catchError((_) {
          // The page came from the office, so it's only a blip; the app's office may be gone for good,
          // and the sign-in page is where you can point it at another.
          if (desktopApp) return goReplace('/login');
          if (mounted) setState(() => _ok = true);
        });
  }

  @override
  Widget build(BuildContext context) => _ok ? widget.child : const ColoredBox(color: Swatch.sky);
}
