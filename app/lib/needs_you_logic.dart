// What "a worker needs you" works out with nothing to draw (features/needsyou/logic.ts): who just started
// asking, what the banner says about them, and when to ring again. No widgets here, so the tests run it as
// it is.

import 'package:office_shared/protocol.dart';
import 'package:office_shared/status.dart' show alertDetail;

/// How long between reminders while a worker's still waiting on an answer nobody's looking at (ms).
const int remindEvery = 30000;

/// One wait of a worker's: asking something else later is another one.
String waitKey(WorkerInfo w) => '${w.id}@${w.waitingSince ?? w.createdAt}';

/// Nobody has its terminal open, so nobody's answering it.
bool unattended(WorkerInfo w) => w.viewers.isEmpty;

/// How long it has waited, for the banner: nothing for the first minute, then "4 min", "1 h 05 min".
String waited(int? since, int now) {
  final min = since == null ? 0 : ((now - since) / 60000).floor();
  if (min < 1) return '';
  return min < 60 ? '$min min' : '${min ~/ 60} h ${(min % 60).toString().padLeft(2, '0')} min';
}

/// What the banner says.
class BannerText {
  const BannerText({required this.id, required this.title, required this.detail, required this.more});

  /// The worker it takes you to: whoever has waited longest.
  final String id;
  final String title;

  /// What it's asking, and for how long.
  final String detail;

  /// How many more are asking, or ''.
  final String more;

  /// Changes whenever the banner would read differently.
  String get key => '$id|$title|$detail|$more';

  @override
  bool operator ==(Object other) => other is BannerText && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// What the banner says about [asking] (longest first, see needingYou), or null with nobody to show.
BannerText? bannerText(List<WorkerInfo> asking, int now) {
  if (asking.isEmpty) return null;
  final w = asking.first;
  final ask = alertDetail(w)?.replaceAll(RegExp(r'\s+'), ' ').trim();
  final detail = [
    if (ask != null && ask.isNotEmpty) ask.length > 90 ? '${ask.substring(0, 89)}…' : ask,
    waited(w.waitingSince, now),
  ].where((s) => s.isNotEmpty).join(' · ');
  return BannerText(
    id: w.id,
    title: '${w.name} needs you',
    detail: detail,
    more: asking.length > 1 ? '+${asking.length - 1} more' : '',
  );
}

/// Tells a worker that has just stopped to ask something from one that was asking already when the page
/// first saw it.
class Fresh {
  final Map<String, WorkerStatus> _last = {};

  /// The workers that started needing you since the last look.
  List<WorkerInfo> take(Map<String, WorkerInfo> workers) {
    final out = <WorkerInfo>[];
    for (final w in workers.values) {
      final before = _last[w.id];
      _last[w.id] = w.status;
      if (before != null && before != w.status && w.status == WorkerStatus.needsInput) out.add(w);
    }
    // Gone, or on a floor you've left: new to the page if it comes back.
    _last.removeWhere((id, _) => !workers.containsKey(id));
    return out;
  }
}

/// When to ring again: every [remindEvery] for as long as someone's asking and nobody's at its terminal.
class Reminders {
  double _last = 0;
  bool _waiting = false;

  /// The alarm just rang: the next reminder is a whole wait away.
  void rang(double now) {
    _last = now;
    _waiting = true;
  }

  /// Nobody the last wait was for is here any more (you've changed floors): the next one starts from scratch.
  void quiet() => _waiting = false;

  /// Whether to ring now, for [asking] (the workers that need you). Says yes once per wait.
  bool due(List<WorkerInfo> asking, double now) {
    if (!asking.any(unattended)) {
      _waiting = false;
      return false;
    }
    // Someone's asking again (or was when the page came up): the wait starts here, quietly.
    if (!_waiting) {
      rang(now);
      return false;
    }
    if (now - _last < remindEvery) return false;
    _last = now;
    return true;
  }
}
