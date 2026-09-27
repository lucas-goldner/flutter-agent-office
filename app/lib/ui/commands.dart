// The commands and links the invite, accounts and services windows hand out (from ui/team.ts,
// ui/accounts.ts and ui/services.ts), kept apart from the windows so they can be tested.

import 'package:flutter/foundation.dart';

import '../shared/protocol.dart';

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

/// Where a worker's server opens once tunnelled: the tunnel lands on the office's own port, so it
/// speaks whatever the office speaks.
String serviceUrl(int port, {bool secure = false}) => '${secure ? 'https' : 'http'}://localhost:$port';

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
