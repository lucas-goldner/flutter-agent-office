// A floor's basketball. Port of src/server/court.ts.

import 'package:office_shared/shared.dart';

/// How often one person can pick the ball up, at most (ms): and so throw it, as it has to be in their hands.
const _every = 150;

/// A floor's basketball: who has it in their hands, or how it was last thrown. The office only keeps
/// track of that much; each page flies the ball from the throw itself (see office_shared's hoop.dart),
/// so where it lands is the same for everyone without the office working it out.
class Court {
  Court([int Function()? now]) : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final int Function() _now;
  String? _holder;
  ({BallThrow at, String by, int time})? _shot;
  final _last = <String, int>{};

  /// The ball as it is now, for the floor's pages.
  BallState state() {
    if (_holder != null) return BallState(holder: _holder);
    final s = _shot;
    if (s == null) return const BallState();
    final elapsed = _now() - s.time;
    return BallState(
      shot: BallShot(
        x: s.at.x,
        y: s.at.y,
        z: s.at.z,
        vx: s.at.vx,
        vy: s.at.vy,
        vz: s.at.vz,
        by: s.by,
        elapsed: elapsed < 0 ? 0 : elapsed,
      ),
    );
  }

  /// [id] picks the ball up (or catches it): only if nobody else has it. Says whether anything changed.
  bool take(String id) {
    if (_holder != null || _tooSoon(id)) return false;
    _holder = id;
    _shot = null;
    return true;
  }

  /// [id] throws the ball they have (or drops it, slowly). Says whether anything changed.
  bool throwBall(String id, BallThrow s) {
    if (_holder != id || !throwOk(s)) return false;
    _holder = null;
    _shot = (at: s, by: id, time: _now());
    return true;
  }

  /// [id] left the floor (or the office): the ball in their hands goes back under the hoop. Says whether it did.
  bool left(String id) {
    _last.remove(id);
    if (_holder != id) return false;
    _holder = null;
    _shot = null;
    return true;
  }

  bool _tooSoon(String id) {
    final now = _now();
    final last = _last[id];
    if (last != null && now - last < _every) return true;
    _last[id] = now;
    return false;
  }
}
