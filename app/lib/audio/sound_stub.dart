// The office's sound off the web: silent. Everything is synthesised with Web Audio (sound_web.dart);
// the desktop app gets its own engine in stage 2 (e.g. flutter_soloud). Until then this takes the
// same calls and plays nothing, and the jukebox and settings say so.

import 'package:office_shared/protocol.dart' show GongWhy;

import 'sound_model.dart';

export 'sound_model.dart' show Ding, DogSounds, JukeboxPlay, SoundListener, StepKind;

class OfficeSound implements DogSounds {
  OfficeSound({double Function()? clock});

  /// A stream that won't play here.
  void Function(String text)? onMusicError;

  /// How many of each sound have played (none).
  final Map<String, int> played = {};

  void dispose() {}
  void setVolume(double volume, bool muted) {}
  void setWeather(double rain, double night) {}
  double level() => 0;
  double musicLevel() => 0;
  String get state => 'unavailable';
  void unlock() {}
  void update(SoundListener l) {}
  void setTyping(String id, double x, double z, bool on) {}
  void removeTypist(String id) {}
  void step([StepKind kind = StepKind.walk]) {}
  void stepAt(double x, double z, [double y = 0]) {}
  void coffee() {}
  @override
  void bark(double x, double z, int times) {}
  @override
  void yip(double x, double z) {}
  void thunder(double delay, double loud) {}
  void gong(GongWhy why) {}
  void ding(Ding kind) {}
  void setJukebox(JukeboxPlay? play) {}
  void setMusicVolume(double volume, bool muted) {}

  /// The jukebox's lights stay still.
  double beat() => 0;
}
