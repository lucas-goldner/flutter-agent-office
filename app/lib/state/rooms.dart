// What the games and rooms on your floor need from the office (the arcade cabinet, the basketball,
// the meeting room, the machine monitor, golf shots), kept up to date from the server's messages.
// Its own listeners, beside the Store's topics, so it stays apart from everything else in state.ts.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:office_shared/cabinet.dart';
import 'package:office_shared/hoop.dart';
import 'package:office_shared/protocol.dart';

import 'store.dart' show nowMs;

class Rooms {
  /// Who's at the arcade cabinet on your floor, and the building's high scores.
  CabinetState cabinet = const CabinetState();

  /// What's on the cabinet's screen while someone else plays (null with nobody on it).
  CabinetFrame? cabinetFrame;
  final ChangeNotifier cabinetChanged = _Notifier();
  final ChangeNotifier cabinetFrameChanged = _Notifier();

  /// The basketball: who has it, or how it was last thrown, and when ([nowMs]) that throw left their hands.
  BallState ball = const BallState();
  double ballSince = 0;
  final ChangeNotifier ballChanged = _Notifier();

  /// The meeting room: who's meeting about what, and the meetings before.
  MeetingState meeting = const MeetingState();
  final ChangeNotifier meetingChanged = _Notifier();

  /// How busy the office's machine is.
  MachineState machine = MachineState.empty;
  final ChangeNotifier machineChanged = _Notifier();

  /// Golf shots from anyone on your floor, you included.
  final StreamController<GolfMsg> _golf = StreamController.broadcast();
  Stream<GolfMsg> get golf => _golf.stream;

  void _emit(ChangeNotifier n) => (n as _Notifier).emit();

  void _enter(FloorView v) {
    cabinet = v.cabinet;
    cabinetFrame = v.cabinet.frame;
    _setBall(v.ball);
    meeting = v.meeting;
    _emit(cabinetChanged);
    _emit(cabinetFrameChanged);
    _emit(ballChanged);
    _emit(meetingChanged);
  }

  void _setBall(BallState b) {
    ball = b;
    ballSince = nowMs() - (b.shot?.elapsed ?? 0);
  }

  void apply(ServerMsg msg) {
    switch (msg) {
      case WelcomeMsg m:
        machine = m.machine;
        _emit(machineChanged);
        _enter(m.view);
      case FloorEnterMsg m:
        _enter(m.view);
      case CabinetMsg m:
        cabinet = m.state;
        if (m.state.player == null) cabinetFrame = null;
        _emit(cabinetChanged);
      case CabinetFrameMsg m:
        cabinetFrame = m.frame;
        _emit(cabinetFrameChanged);
      case BallMsg m:
        _setBall(m.ball);
        _emit(ballChanged);
      case MeetingMsg m:
        meeting = m.state;
        _emit(meetingChanged);
      case MachineMsg m:
        machine = m.state;
        _emit(machineChanged);
      case GolfMsg m:
        _golf.add(m);
      default:
        break;
    }
  }
}

class _Notifier extends ChangeNotifier {
  void emit() => notifyListeners();
}
