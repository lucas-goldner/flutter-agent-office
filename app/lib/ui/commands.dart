// The commands and links the invite, accounts and services windows hand out (from ui/team.ts,
// ui/accounts.ts and ui/services.ts), kept apart from the windows so they can be tested.

import 'package:flutter/foundation.dart';

import 'package:office_shared/protocol.dart';

/// The host OS, for which command opens a URL: on the web Flutter reads it off the browser.
enum Os { mac, linux, windows }

const Map<Os, String> osLabel = {Os.mac: 'macOS', Os.linux: 'Linux', Os.windows: 'Windows'};

Os guessOs() => switch (defaultTargetPlatform) {
  TargetPlatform.windows => Os.windows,
  TargetPlatform.macOS || TargetPlatform.iOS => Os.mac,
  _ => Os.linux,
};

/// Opens a URL in the browser, for ssh's LocalCommand.
String openCommand(String url, Os os) => switch (os) {
  Os.mac => 'open $url',
  Os.windows => 'start $url',
  Os.linux => 'xdg-open $url >/dev/null 2>&1 &',
};

/// One command that opens the tunnel and, once it's up, the office in their browser.
String tunnelCommand(TeamState t, Os os) {
  // LocalCommand runs after the forward is listening, so the page loads on the first try.
  final open = openCommand('http://localhost:${t.port}', os);
  return 'ssh -o ExitOnForwardFailure=yes -o PermitLocalCommand=yes -o LocalCommand="$open" -L ${t.port}:localhost:${t.port} ${t.ssh ?? ''}';
}

String inviteMessage(TeamState t, Os os, String? projectName) {
  final project = projectName ?? 'our';
  final lines = [
    "You're invited to the $project Agent Office. Run this in a terminal (${osLabel[os]}):",
    '',
    tunnelCommand(t, os),
    '',
    "It opens the office at http://localhost:${t.port} — sign in (with the office password, or the account link you get from me) and keep that terminal open while you're in.",
    t.fingerprint != null
        ? 'The first time, ssh asks whether to trust the server. Only say yes if it shows ${t.fingerprint}'
        : '',
  ];
  // No blank line twice in a row.
  final kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].isNotEmpty || (i > 0 && lines[i - 1].isNotEmpty)) kept.add(lines[i]);
  }
  return kept.join('\n').trim();
}

/// On an office on a Tailscale network: the link, and how to get onto the network.
String tailnetMessage(TeamState t, String? projectName) => [
  "You're invited to the ${projectName ?? 'our'} Agent Office: https://${t.tailnet}",
  '',
  "It's on our Tailscale network. If you aren't on it yet: install Tailscale (https://tailscale.com/download), sign in, and accept the invite I send you from Tailscale. Then open the link and sign in with the office password, or the account link you get from me.",
].join('\n');

/// Tailscale's admin console, where someone is let onto the network.
const tailscaleAdmin = 'https://login.tailscale.com/admin';

/// How to run the script that deployed the office (deploy/azure.sh --name x), for the commands the
/// panels suggest: deploy/aws.sh when the office doesn't know.
String deployScript(String? deploy) => deploy ?? 'deploy/aws.sh';

/// Whether this page came over the office's Tailscale network ([hostname] is the page's), where every
/// worker's server has its own link.
bool onTailnet(String? tailnet, String hostname) => tailnet != null && tailnet.isNotEmpty && hostname == tailnet;

/// Whether the office is likely on another machine than this browser, so its workers' ports aren't
/// already here.
bool officeElsewhere(ServicesState s, String hostname) =>
    s.ssh != null || !RegExp(r'^(?:localhost|127\.0\.0\.1|\[::1\]|::1)$').hasMatch(hostname);

/// The command that opens every worker's server on someone's own computer by itself, as each one starts
/// (`agent-office tunnel`). It reaches the office the way this page did ([origin]).
String autoTunnel(String origin) =>
    origin == 'http://localhost:4600' ? 'agent-office tunnel' : 'agent-office tunnel $origin';

/// Where a worker's server opens once tunnelled: the tunnel lands on the office's own port, so it
/// speaks whatever the office speaks. On the office's Tailscale network ([tailnet]), Tailscale Serve
/// points `<office>.ts.net:<port>` at the office, which relays it by the port.
String serviceUrl(int port, {bool secure = false, String? tailnet}) =>
    tailnet != null ? 'https://$tailnet:$port' : '${secure ? 'https' : 'http'}://localhost:$port';

/// One command that tunnels `localhost:<port>` to the office, which relays it to the worker's
/// server, and opens it once the tunnel is up. It uses the same SSH access as the office itself.
String serviceTunnel(ServicesState s, int port, Os os, {bool secure = false}) {
  final open = openCommand(serviceUrl(port, secure: secure), os);
  return 'ssh -N -o ExitOnForwardFailure=yes -o PermitLocalCommand=yes -o LocalCommand="$open" -L $port:localhost:${s.port} ${s.ssh ?? 'you@your-server'}';
}

/// The link that makes one account.
String inviteLink(AccountInvite v, String origin) => '$origin/join#${v.token}';

/// "expires in 3 days", or "expires today".
String expiresIn(int t, [int? now]) {
  final d = ((t - (now ?? DateTime.now().millisecondsSinceEpoch)) / 86400000).round();
  return d >= 1 ? 'expires in $d day${d == 1 ? '' : 's'}' : 'expires today';
}
