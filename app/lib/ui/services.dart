// 🌐 Services: the web servers the workers are running, and a command to open each on your own
// computer through the office (ui/services.ts).

import 'package:flutter/material.dart';

import '../interop/browser.dart';
import '../interop/open_link.dart';
import '../office_scope.dart';

import 'package:office_shared/protocol.dart';

import '../state/store.dart';
import 'commands.dart';
import 'hud_parts.dart' show cssColor;
import 'modal.dart';
import 'theme.dart';
import 'window_parts.dart';

/// The page's own host name, to tell whether it came over the office's Tailscale network.
String get _hostname => Uri.parse(serverOrigin).host;

/// Whether this page came over the office's Tailscale network, where every server has its own link.
bool _direct(ServicesState s) => onTailnet(s.tailnet, _hostname);

/// Where worker's server [port] opens from this page: its own link on the tailnet, or through a tunnel.
String serviceLink(ServicesState s, int port) =>
    serviceUrl(port, secure: isSecure, tailnet: _direct(s) ? s.tailnet : null);

ModalHandle openServices(OfficeScope scope) =>
    ModalStack.instance.show((modal) => _ServicesWindow(scope: scope, modal: modal))
      ..doing = '🌐 at the services board';

class _ServicesWindow extends StatefulWidget {
  const _ServicesWindow({required this.scope, required this.modal});
  final OfficeScope scope;
  final ModalHandle modal;

  @override
  State<_ServicesWindow> createState() => _ServicesWindowState();
}

class _ServicesWindowState extends State<_ServicesWindow> with ListenTo, Ticking {
  Os _os = guessOs();
  int? _picked;
  int? _copied;

  Store get store => widget.scope.store;

  @override
  void initState() {
    super.initState();
    listenTo(store.topics(const [Topic.services, Topic.workers]), () => setState(() {}));
    // Keeps "started 5m ago" fresh.
    tickEvery(const Duration(seconds: 30));
  }

  Future<void> _pick(ServiceInfo svc) async {
    setState(() => _picked = svc.port);
    final s = store.services;
    final ok = await copyText(
      _direct(s) ? serviceLink(s, svc.port) : serviceTunnel(s, svc.port, _os, secure: isSecure),
    );
    if (mounted) setState(() => _copied = ok ? svc.port : null);
  }

  @override
  Widget build(BuildContext context) {
    final s = store.services;
    final direct = _direct(s);
    return ModalWindow(
      modal: widget.modal,
      width: 760,
      title: const Text('🌐 Services'),
      headerExtras: [
        if (!direct)
          SegButtons<Os>(
            options: [for (final o in Os.values) (o, osLabel[o]!)],
            value: _os,
            onPick: (o) => setState(() {
              _os = o;
              _copied = null;
            }),
          ),
      ],
      body: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: _body(s)),
      footer: Row(
        children: [
          FooterNote(
            direct ? 'Every link goes through the office, so the office sign-in still guards every page.' : 'Tunnels go through the office, so the office password still guards every page. Keep the terminal open while you look.',
          ),
        ],
      ),
    );
  }

  List<Widget> _body(ServicesState s) {
    final direct = _direct(s);
    final out = <Widget>[
      Note(
        direct
            ? 'Web servers the workers are running. Each has its own link on your Tailscale network: open it, or click the row to copy it for someone else on the network.'
            : 'Web servers the workers are running. Click one to copy a command that opens it on your computer — run it in a terminal and the page opens by itself.',
        top: 0,
      ),
      const SizedBox(height: 12),
      if (!direct && officeElsewhere(s, _hostname)) _AutoTunnel(autoTunnel(serverOrigin)),
    ];
    if (s.items.isEmpty) {
      out.add(
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 18),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Swatch.muted, width: kBorder),
          ),
          child: Column(
            children: [
              Text('Nothing running yet.', style: heavy(16)),
              Note(
                '',
                top: 8,
                rich: [
                  const TextSpan(text: 'When a worker starts a web server — '),
                  codeSpan('npm run dev'),
                  const TextSpan(text: ', a preview build, '),
                  codeSpan('python -m http.server'),
                  const TextSpan(
                    text: ' — it shows up here within a few seconds. Try prompting: “start the dev server in the background so we can review it”.',
                  ),
                ],
              ),
            ],
          ),
        ),
      );
      return out;
    }
    for (final svc in s.items) {
      out.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: _ServiceRow(
            svc,
            store: store,
            url: serviceLink(s, svc.port),
            direct: direct,
            on: _picked == svc.port,
            onTap: () => _pick(svc),
          ),
        ),
      );
    }
    ServiceInfo? svc;
    for (final i in s.items) {
      if (i.port == _picked) svc = i;
    }
    if (svc != null && direct) {
      final url = serviceLink(s, svc.port);
      out.add(
        _copied == svc.port
            ? StatusBox(
                "✅ Copied $url. Anyone on the network who's signed in to the office can open it.",
                kind: StatusKind.ok,
                top: 4,
              )
            : StatusBox('The link for :${svc.port}: $url', top: 4),
      );
    } else if (svc != null) {
      final url = serviceUrl(svc.port, secure: isSecure);
      final cmd = serviceTunnel(s, svc.port, _os, secure: isSecure);
      out.add(
        _copied == svc.port
            ? StatusBox(
                '✅ Copied. Paste it in a terminal: it opens $url once the tunnel is up.',
                kind: StatusKind.ok,
                top: 4,
              )
            : StatusBox('The command for :${svc.port} — run it in a terminal, and it opens $url.', top: 4),
      );
      out.add(CommandBlock(cmd));
    } else if (_picked != null) {
      out.add(StatusBox('The server on :$_picked stopped.', kind: StatusKind.error, top: 4));
    }
    if (direct) return out;
    out.add(
      s.ssh != null
          ? Note(
              '',
              top: 8,
              rich: [
                const TextSpan(
                  text: 'It uses the same SSH access as the office. Not invited yourself (you set the office up)? Run ',
                ),
                codeSpan('${deployScript(s.deploy)} service <port>'),
                const TextSpan(text: ' instead.'),
              ],
            )
          : Note(
              '',
              top: 8,
              rich: [
                const TextSpan(text: 'Replace '),
                codeSpan('you@your-server'),
                const TextSpan(
                  text: " with how you SSH to the office's machine. If the office runs on this computer, just click Open.",
                ),
              ],
            ),
    );
    return out;
  }
}

/// `agent-office tunnel`: every worker's server opens on your own computer by itself (#273).
class _AutoTunnel extends StatelessWidget {
  const _AutoTunnel(this.command);
  final String command;

  @override
  Widget build(BuildContext context) => Container(
    key: const ValueKey('svc-auto'),
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    decoration: BoxDecoration(
      color: Swatch.paper2,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Swatch.ink, width: kBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('⚡ Open them all, by themselves', style: heavy(14)),
        Note(
          '',
          top: 4,
          rich: [
            const TextSpan(
              text: 'Run this on your computer and leave it running. Every server a worker starts opens on the same port there (',
            ),
            codeSpan('localhost:5173'),
            const TextSpan(text: ' is the worker’s), and closes when the worker stops it. It needs the '),
            codeSpan('agent-office'),
            const TextSpan(text: ' command on your computer: the install line in the README.'),
          ],
        ),
        CommandBlock(command),
      ],
    ),
  );
}

class _ServiceRow extends StatefulWidget {
  const _ServiceRow(
    this.svc, {
    required this.store,
    required this.url,
    required this.direct,
    required this.on,
    required this.onTap,
  });
  final ServiceInfo svc;
  final Store store;
  final String url;

  /// On the office's Tailscale network: the row copies its link, not a tunnel command.
  final bool direct;
  final bool on;
  final VoidCallback onTap;

  @override
  State<_ServiceRow> createState() => _ServiceRowState();
}

class _ServiceRowState extends State<_ServiceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final svc = widget.svc;
    final w = widget.store.workers[svc.workerId];
    final url = widget.url;
    final meta = [
      w?.name ?? 'A worker',
      if (w?.worktree != null) '🌿 ${w!.worktree!.branch}',
      if (svc.title != null && svc.title!.isNotEmpty) svc.command,
      'started ${timeAgo(svc.since)}',
    ].join(' · ');
    return Tooltip(
      message: widget.direct ? 'Copy the link' : 'Copy the tunnel command',
      waitDuration: const Duration(milliseconds: 700),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: widget.on
                  ? Swatch.paper2
                  : _hover
                  ? Swatch.paper2
                  : Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: widget.on ? Swatch.accent : Swatch.ink, width: kBorder),
              boxShadow: const [BoxShadow(color: Swatch.ink, offset: Offset(0, 3))],
            ),
            child: Row(
              children: [
                Dot(cssColor(w?.color ?? '#8d99ae'), size: 14),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        svc.title != null && svc.title!.isNotEmpty ? svc.title! : svc.command,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heavy(16, weight: FontWeight.w900),
                      ),
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: heavy(12, color: Swatch.muted, weight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  ':${svc.port}',
                  style: const TextStyle(
                    fontFamily: kMono,
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: Swatch.ink,
                  ),
                ),
                const SizedBox(width: 12),
                SmallButton(
                  label: 'Open ↗',
                  tooltip: widget.direct
                      ? 'Open $url'
                      : 'Open $url (needs the tunnel, unless the office runs on this computer)',
                  onPressed: () => openInNewTab(url),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
