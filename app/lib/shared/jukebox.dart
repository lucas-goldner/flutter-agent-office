// The lounge jukebox: the tunes it has and what it's playing, shared by the server (which keeps one
// per floor) and the browser (which synthesizes the tunes, see client/music.ts).

import 'decor.dart' show UrlCheck, parseWebUrl;
import 'json_util.dart';

class JukeboxTune {
  const JukeboxTune({required this.id, required this.title, required this.mood});

  final String id;
  final String title;

  /// A few words on the card in its list.
  final String mood;
}

const List<JukeboxTune> jukeboxTunes = [
  JukeboxTune(id: 'rainy-window', title: 'Rainy Window', mood: 'slow and dreamy'),
  JukeboxTune(id: 'coffee-break', title: 'Coffee Break', mood: 'jazzy, easy swing'),
  JukeboxTune(id: 'late-commit', title: 'Late Commit', mood: 'minor key, 2 a.m.'),
  JukeboxTune(id: 'green-build', title: 'Green Build', mood: 'bright and bouncy'),
];

/// The `track` of a stream someone pasted.
const String jukeboxStream = 'stream';

class JukeboxState {
  const JukeboxState({required this.on, required this.track, this.url, this.by, required this.startedAt, required this.elapsed});

  factory JukeboxState.fromJson(Map<String, dynamic> j) => JukeboxState(
        on: asBool(j['on']),
        track: asString(j['track'], jukeboxTunes.first.id),
        url: asStringOrNull(j['url']),
        by: asStringOrNull(j['by']),
        startedAt: asDouble(j['startedAt']),
        elapsed: asDouble(j['elapsed']),
      );

  final bool on;

  /// One of [jukeboxTunes], or [jukeboxStream] for `url`. It stays put while the jukebox is off, to turn back on.
  final String track;

  /// Internet radio or an audio file someone pasted.
  final String? url;

  /// Who last put something on, or turned it off.
  final String? by;

  /// When the track started, on the office's clock (see the 'pong' message), so everyone hears the same bar.
  final double startedAt;

  /// How far into the track it was when this was sent, in ms, for until the clocks are compared.
  final double elapsed;

  Map<String, dynamic> toJson() => {
        'on': on,
        'track': track,
        'url': ?url,
        'by': ?by,
        'startedAt': startedAt,
        'elapsed': elapsed,
      };
}

JukeboxTune? tuneById(String id) {
  for (final t in jukeboxTunes) {
    if (t.id == id) return t;
  }
  return null;
}

/// What's on, for the hint bar and the jukebox's own display: a tune's title, or where the stream comes from.
String trackTitle(String track, String? url) {
  if (track != jukeboxStream) return tuneById(track)?.title ?? 'A tune';
  try {
    final u = parseWebUrl(url ?? '');
    if (u == null) return 'A stream';
    final segs = u.path.split('/').where((s) => s.isNotEmpty);
    final file = segs.isEmpty ? '' : Uri.decodeComponent(segs.last);
    return file.isNotEmpty ? '${u.host} · $file' : u.host;
  } catch (_) {
    return 'A stream';
  }
}

UrlCheck checkStreamUrl(Object? raw) {
  final s = raw is String ? raw.trim() : '';
  if (s.isEmpty) return (url: null, error: 'Paste a link to a stream or an audio file');
  if (s.length > 2048) return (url: null, error: 'That link is too long');
  final u = parseWebUrl(s);
  if (u == null) return (url: null, error: "That isn't a web link. Paste an address that starts with https://");
  if (u.scheme != 'https' && u.scheme != 'http') return (url: null, error: 'Only http and https links can play on the jukebox');
  return (url: u.toString(), error: null);
}
