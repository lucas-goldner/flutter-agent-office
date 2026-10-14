// Speech to text for dictating a prompt (ui/speech.ts): the transcript bookkeeping, push to talk, and
// listening on and on with a recognizer that gives up after a pause. The recognizer itself is the
// browser's own (interop/speech.dart); this works on any [Recognizer], so it's tested with a fake.

/// One of the recognizer's results: the words of its best guess, and whether it has settled on them.
typedef RecResult = ({String transcript, bool isFinal});

/// What [Recognizer.start] throws when it won't start.
class RecognizerError implements Exception {
  const RecognizerError(this.message);
  final String message;

  @override
  String toString() => message;
}

/// The parts of the Web Speech API's SpeechRecognition used here.
abstract class Recognizer {
  String lang = 'en-US';
  bool continuous = false;
  bool interimResults = false;

  /// Recognize on the device (Chrome 139+, once the model for [lang] is installed).
  bool processLocally = false;

  /// Everything heard so far, each time it changes.
  void Function(List<RecResult> results)? onresult;
  void Function(String error)? onerror;
  void Function()? onend;

  void start();
  void stop();
  void abort();
}

typedef RecognizerFactory = Recognizer Function();

/// What was said, as plain text on one line: nothing a terminal would take for a key.
String cleanSpoken(String text) =>
    text.replaceAll(RegExp(r'[\u0000-\u001f\u007f-\u009f]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();

/// Puts what was said into a field's text in place of its selection ([start]..[end]), with a space on
/// either side where words would otherwise run together. The new text, and where the cursor goes.
({String value, int caret}) spliceSpoken(String value, int start, int end, String spoken) {
  final text = cleanSpoken(spoken);
  if (text.isEmpty) return (value: value, caret: start);
  final before = value.substring(0, start);
  final after = value.substring(end);
  final lead =
      before.isNotEmpty && !RegExp(r'''[\s(\[{"'“‘/-]$''').hasMatch(before) && !RegExp(r'^[.,!?;:)\]}%]').hasMatch(text)
      ? ' '
      : '';
  final trail = after.isNotEmpty && !RegExp(r'^[\s.,!?;:)\]}]').hasMatch(after) ? ' ' : '';
  final put = lead + text + trail;
  return (value: before + put + after, caret: before.length + put.length);
}

/// Follows a recognizer's results as it listens. Each event lists everything heard so far: the phrases
/// it has settled on (final) and, after them, what it's still working out. [take] hands back the
/// phrases that settled since the last call, each once, and the words still up in the air.
class Transcript {
  /// How many results have been handed out as said.
  int _done = 0;

  ({List<String> said, String interim}) take(List<RecResult> results) {
    final said = <String>[];
    while (_done < results.length && results[_done].isFinal) {
      final text = cleanSpoken(results[_done].transcript);
      if (text.isNotEmpty) said.add(text);
      _done++;
    }
    final interim = StringBuffer();
    for (var i = _done; i < results.length; i++) {
      interim.write(results[i].transcript);
    }
    return (said: said, interim: cleanSpoken(interim.toString()));
  }
}

/// Why listening stopped when it wasn't asked to, in words for a toast. Null when it was only cut off
/// (by another window listening, say).
String? speechProblem(String code, String lang) => switch (code) {
  'aborted' => null,
  'not-allowed' => 'Dictation needs the microphone: allow it for this page in the address bar, then try again.',
  'audio-capture' => 'Dictation found no microphone to listen to.',
  'network' || 'service-not-allowed' => "This browser's speech service didn't answer, so there's nothing to take dictation. Chrome, Edge and Safari have one; Brave and some others come without it.",
  'language-not-supported' => "This browser can't take dictation in $lang.",
  _ => 'Dictation stopped: $code.',
};

abstract class Listening {
  /// Stops listening and hands over what it has heard so far.
  void stop();

  /// Stops listening and throws away what it hasn't handed over yet.
  void abort();
}

class ListenHandlers {
  const ListenHandlers({required this.interim, required this.said, required this.end});

  /// The words it's still working out, as they change.
  final void Function(String text) interim;

  /// A phrase it has settled on.
  final void Function(String text) said;

  /// It's over, with what went wrong if something did (see [speechProblem]).
  final void Function(String? problem) end;
}

/// A browser's recognizer gives up after a while of silence: it's started again, until it has heard
/// nothing for this long (ms).
const int quietMs = 60000;

/// A recognizer that ends this soon after starting (ms) isn't started again: it would only end again.
const int _tooSoonMs = 1000;

class _Nothing implements Listening {
  @override
  void stop() {}
  @override
  void abort() {}
}

/// Listens until told to stop, handing over each phrase as the recognizer settles on it. [ListenHandlers.end]
/// is called once, whoever ends it. [make] is the browser's recognizer (null: it has none); on a [phone]
/// (Chrome on Android) it's a phrase at a time. [local]: the on-device model for [lang] is there.
Listening listen(
  ListenHandlers on, {
  required RecognizerFactory? make,
  String lang = 'en-US',
  int Function()? now,
  bool phone = false,
  bool local = false,
}) {
  final clock = now ?? () => DateTime.now().millisecondsSinceEpoch;
  if (make == null) {
    on.end('This browser has no speech recognition built in. Chrome, Edge and Safari do.');
    return _Nothing();
  }
  return _Listen(on, make(), lang, clock, phone, local);
}

class _Listen implements Listening {
  _Listen(this.on, this.rec, String lang, this.now, bool phone, bool local) : _lang = lang {
    rec
      ..lang = lang
      // Chrome on Android repeats itself when it listens on and on, and calls its guesses final: there
      // it's a phrase at a time, started again after each (see _ended), and only what it settled on.
      ..continuous = !phone
      ..interimResults = !phone
      ..processLocally = local
      ..onresult = _result
      ..onerror = _error
      ..onend = _ended;
    _startedAt = now();
    _heardAt = _startedAt;
    if (!_begin()) _finish();
  }

  final ListenHandlers on;
  final Recognizer rec;
  final int Function() now;
  final String _lang;
  Transcript _transcript = Transcript();
  bool _over = false;

  /// Asked to stop: what ends it now is the end.
  bool _stopping = false;
  String? _problem;
  late int _startedAt;
  late int _heardAt;

  /// The words it was still working out when last heard from.
  String _pending = '';

  void _finish() {
    if (_over) return;
    _over = true;
    rec
      ..onresult = null
      ..onerror = null
      ..onend = null;
    on.end(_problem);
  }

  bool _begin() {
    try {
      rec.start();
      return true;
    } catch (err) {
      _problem ??= "Dictation couldn't start: ${err is RecognizerError ? err.message : err}";
      return false;
    }
  }

  void _result(List<RecResult> results) {
    if (_over) return;
    _heardAt = now();
    final r = _transcript.take(results);
    for (final text in r.said) {
      on.said(text);
    }
    _pending = r.interim;
    on.interim(r.interim);
  }

  void _error(String code) {
    // A pause, which ends it: it's started again below while you still want it.
    if (code == 'no-speech') return;
    _problem ??= speechProblem(code, _lang);
    _stopping = true;
  }

  void _ended() {
    if (_over) return;
    // Ended before it settled on its last words: they're what it heard, so they count.
    if (_pending.isNotEmpty) on.said(_pending);
    _pending = '';
    on.interim('');
    final t = now();
    // It gave up on its own (a pause, or its service's time limit) while you still want it.
    if (!_stopping && t - _startedAt >= _tooSoonMs && t - _heardAt < quietMs) {
      _startedAt = t;
      // Its results count from nothing again.
      _transcript = Transcript();
      if (_begin()) return;
    }
    _finish();
  }

  @override
  void stop() {
    if (_over || _stopping) return;
    _stopping = true;
    try {
      rec.stop();
    } catch (_) {
      _finish();
    }
  }

  @override
  void abort() {
    if (_over) return;
    _stopping = true;
    // Nothing more is wanted from it, not even the phrase it was in the middle of.
    rec.onresult = null;
    try {
      rec.abort();
    } catch (_) {
      // already stopped
    }
    _finish();
  }
}

/// A press this long (ms) is a hold: letting go ends it. A shorter one is a tap, which leaves it on until
/// the next press.
const int holdMs = 350;

/// Push to talk, for a button and a key alike: pressing starts listening, and letting go of a hold stops
/// it. A quick tap leaves it listening, hands free, until the next press.
class PushToTalk {
  PushToTalk({required this.live, required this.start, required this.stop, int Function()? now})
    : _now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final bool Function() live;
  final void Function() start;
  final void Function() stop;
  final int Function() _now;

  bool _held = false;

  /// This press is the one that started it.
  bool _mine = false;
  int _downAt = 0;

  bool get down => _held;

  void press() {
    if (_held) return;
    _held = true;
    _mine = !live();
    _downAt = _now();
    if (_mine) start();
  }

  void release() {
    if (!_held) return;
    _held = false;
    if (!_mine || _now() - _downAt >= holdMs) stop();
  }
}

/// Whether the on-device model for a language is installed, once the browser has said (it's asked once).
final Map<String, bool> _onDevice = {};

/// Asks [available] ahead of time, so starting to listen never waits on the answer.
void checkOnDevice(String lang, Future<bool> Function(String lang)? available) {
  if (_onDevice.containsKey(lang) || available == null) return;
  _onDevice[lang] = false;
  available(lang).then((ok) => _onDevice[lang] = ok, onError: (_) => false);
}

/// Whether [lang] can be recognized on the device, as far as is known yet.
bool onDevice(String lang) => _onDevice[lang] ?? false;
