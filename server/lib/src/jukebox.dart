import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart' hide Jukebox;
import 'package:path/path.dart' as p;

/// What jukebox.json keeps.
class _Saved {
  const _Saved({required this.on, required this.track, this.url, this.by, required this.startedAt});

  final bool on;
  final String track;
  final String? url;
  final String? by;

  /// When the track started, on this machine's clock.
  final int startedAt;

  Map<String, dynamic> toJson() => {'on': on, 'track': track, 'url': ?url, 'by': ?by, 'startedAt': startedAt};
}

int _now() => DateTime.now().millisecondsSinceEpoch;

/// The lounge jukebox on one floor, saved in .agent-office/jukebox.json. It only says what's on and
/// since when; every browser plays it for itself, from the same point.
class Jukebox {
  Jukebox(String dataDir) : _file = p.join(dataDir, 'jukebox.json') {
    _load();
  }

  _Saved _s = _Saved(on: false, track: jukeboxTunes[0].id, startedAt: _now());
  final String _file;

  JukeboxState state() {
    final s = _s;
    return JukeboxState(
      on: s.on,
      track: s.track,
      url: s.url != null && s.url!.isNotEmpty && s.track == jukeboxStream ? s.url : null,
      by: s.by != null && s.by!.isNotEmpty ? s.by : null,
      startedAt: s.startedAt.toDouble(),
      elapsed: (_now() - s.startedAt).clamp(0, double.maxFinite).toDouble(),
    );
  }

  /// What's on, for toasts: “Rainy Window”, or where a stream comes from.
  String title() => trackTitle(_s.track, _s.url);

  /// Puts on a tune, a stream, or (with neither) whatever it had. Says whether anything changed, or why it can't.
  ({bool changed, String? error}) play(({Object? track, Object? url}) input, String by) {
    final (:track, :url) = input;
    if (url != null && url != '') {
      final u = checkStreamUrl(url);
      if (u.url == null) return (changed: false, error: u.error);
      _set(on: true, track: jukeboxStream, url: u.url, by: by);
    } else if (track != null) {
      if (track is! String || tuneById(track) == null) {
        return (changed: false, error: "The jukebox doesn't have that one");
      }
      _set(on: true, track: track, by: by);
    } else {
      if (_s.on) return (changed: false, error: null);
      _set(on: true, track: _s.track, url: _s.url, by: by);
    }
    return (changed: true, error: null);
  }

  /// On to the next tune; from a stream, back to the first one.
  void skip(String by) {
    final i = jukeboxTunes.indexWhere((t) => t.id == _s.track);
    _set(on: true, track: jukeboxTunes[(i + 1) % jukeboxTunes.length].id, by: by);
  }

  bool stop(String by) {
    if (!_s.on) return false;
    _s = _Saved(on: false, track: _s.track, url: _s.url, by: by, startedAt: _s.startedAt);
    _save();
    return true;
  }

  void _set({required bool on, required String track, String? url, String? by}) {
    _s = _Saved(on: on, track: track, url: url, by: by, startedAt: _now());
    _save();
  }

  void _load() {
    final file = File(_file);
    if (!file.existsSync()) return;
    try {
      final s = jsonDecode(file.readAsStringSync());
      if (s is! Map) return;
      final track = s['track'];
      final url = track == jukeboxStream ? checkStreamUrl(s['url']) : null;
      if (track == jukeboxStream ? url == null || url.url == null : track is! String || tuneById(track) == null) return;
      final by = s['by'];
      final startedAt = s['startedAt'];
      _s = _Saved(
        on: s['on'] == true,
        track: track as String,
        url: url?.url,
        by: by is String ? (by.length > 24 ? by.substring(0, 24) : by) : null,
        startedAt: startedAt is num && startedAt.isFinite ? startedAt.toInt() : _now(),
      );
    } catch (_) {
      // a broken file just means a quiet lounge
    }
  }

  void _save() {
    try {
      _writePrivate(_file, const JsonEncoder.withIndent('  ').convert(_s.toJson()));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }
}

/// Writes [text] to [file] readable by this user only: to `<file>.tmp` first, then moved into place.
void _writePrivate(String file, String text) {
  final tmp = '$file.tmp';
  File(tmp).writeAsStringSync(text);
  if (!Platform.isWindows) {
    try {
      Process.runSync('chmod', ['600', tmp]);
    } catch (_) {
      // no chmod: the folder around it is private anyway
    }
  }
  File(tmp).renameSync(file);
}
