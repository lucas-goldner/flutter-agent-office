// Dictation (ui/dictate.ts): a 🎤 on a prompt box and in a worker's terminal. Hold it (or Ctrl+Space) and
// talk, and what you said is typed in where the cursor is once you let go; a quick tap leaves it
// listening, hands free, until the next one. Nothing is sent for you: you read it over and press Enter
// yourself. The listening is the browser's own (interop/speech.dart), so where a browser has none (Firefox,
// the desktop app) there's no 🎤.

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../interop/speech.dart' as speech;
import 'modal.dart' show toast, ToastKind;
import 'speech_logic.dart';
import 'theme.dart';

/// Stands in for the browser's recognizer in tests: what [Dictation] listens with, and whether the page
/// is secure.
@visibleForTesting
({RecognizerFactory? make, bool secure})? debugSpeech;

/// The clock push to talk times a hold by, in tests.
@visibleForTesting
int Function()? debugDictateNow;

RecognizerFactory? _make() => debugSpeech != null ? debugSpeech!.make : speech.recognizer();

speech.SpeechSupport _support() {
  final d = debugSpeech;
  if (d == null) return speech.speechSupport();
  if (d.make == null) return speech.SpeechSupport.none;
  return d.secure ? speech.SpeechSupport.ok : speech.SpeechSupport.insecure;
}

/// Whether there's a 🎤 at all.
bool get canDictate => _support() != speech.SpeechSupport.none;

const _title =
    'Dictate: hold to talk (or hold Ctrl+Space) and let go, and what you said is typed in. A quick click leaves it listening until you click again';

/// True while dictation listens: voice chat mutes an open mic meanwhile (see the controller).
final ValueNotifier<bool> dictating = ValueNotifier(false);

/// The one that's listening now: there's one microphone, so a second 🎤 cuts off the first.
Dictation? _active;

/// The end of what's being heard, which is the part that's changing.
String _tail(String text, [int max = 90]) => text.length > max ? '…${text.substring(text.length - max)}' : text;

/// One 🎤 and what it types into: [insert] puts a phrase where the cursor is, and [off] says it can't
/// take words right now (a worker that's asleep).
class Dictation extends ChangeNotifier {
  Dictation({required this.insert, this.off}) {
    if (canDictate) checkOnDevice(speech.speechLang(), debugSpeech != null ? null : speech.speechOnDevice());
    _talk = PushToTalk(
      live: () => _listening != null,
      start: start,
      stop: () => _listening?.stop(),
      now: debugDictateNow,
    );
  }

  final void Function(String text) insert;
  final bool Function()? off;
  late final PushToTalk _talk;
  Listening? _listening;
  String _interim = '';
  bool _keyHeld = false;
  bool _disposed = false;

  bool get listening => _listening != null;

  /// What it shows over the box while it listens; null when it doesn't.
  String? get live => !listening
      ? null
      : _interim.isNotEmpty
      ? '🎙️ ${_tail(_interim)}'
      : '🎙️ Listening…';

  void _paint([String interim = '']) {
    _interim = interim;
    if (!_disposed) notifyListeners();
  }

  void start() {
    if (_listening != null || (off?.call() ?? false)) return;
    if (_support() == speech.SpeechSupport.insecure) {
      toast(
        'Dictation needs HTTPS (or localhost), like voice. Ask whoever runs the office to enable TLS.',
        ToastKind.warn,
      );
      return;
    }
    _active?._listening?.abort();
    var over = false;
    Listening? mine;
    final lang = speech.speechLang();
    mine = listen(
      ListenHandlers(
        interim: _paint,
        said: insert,
        end: (problem) {
          over = true;
          if (_listening != null && identical(_listening, mine)) {
            _listening = null;
            if (identical(_active, this)) _active = null;
            dictating.value = false;
          }
          _paint();
          if (problem != null) toast(problem, ToastKind.warn);
        },
      ),
      make: _make(),
      lang: lang,
      phone: debugSpeech == null && speech.speechOnPhone(),
      local: onDevice(lang),
    );
    // It couldn't even start.
    if (over) return;
    _listening = mine;
    _active = this;
    _paint();
    dictating.value = true;
  }

  /// The 🎤 pressed down, and let go (anywhere).
  void press() => _talk.press();
  void release() => _talk.release();

  /// The 🎤 from the keyboard: there's no letting go to wait for, so it turns on, or off.
  void toggle() => _listening != null ? _listening!.stop() : start();

  /// Give it each key of what's being dictated into: true when it was Ctrl+Space, which it took. Held
  /// down it's push to talk; letting go of either key ends it, wherever that happens.
  bool key(KeyEvent e) {
    if (e is KeyUpEvent) return false;
    final kb = HardwareKeyboard.instance;
    if (e.physicalKey != PhysicalKeyboardKey.space ||
        !kb.isControlPressed ||
        kb.isAltPressed ||
        kb.isMetaPressed ||
        kb.isShiftPressed) {
      return false;
    }
    // The key repeats while it's held.
    if (e is KeyRepeatEvent || _talk.down) return true;
    _talk.press();
    if (!_keyHeld) {
      _keyHeld = true;
      HardwareKeyboard.instance.addHandler(_onKeyUp);
    }
    return true;
  }

  bool _onKeyUp(KeyEvent e) {
    if (e is KeyUpEvent &&
        (e.physicalKey == PhysicalKeyboardKey.space ||
            e.logicalKey == LogicalKeyboardKey.controlLeft ||
            e.logicalKey == LogicalKeyboardKey.controlRight)) {
      _letGo();
    }
    return false;
  }

  void _letGo() {
    if (_keyHeld) {
      _keyHeld = false;
      HardwareKeyboard.instance.removeHandler(_onKeyUp);
    }
    _talk.release();
  }

  /// Stops listening, for good: what was being dictated into is gone.
  @override
  void dispose() {
    _letGo();
    _talk.release();
    _listening?.abort();
    _disposed = true;
    super.dispose();
  }
}

/// The 🎤 ([label] after it in a terminal's header). Held down it's push to talk, and it never takes the
/// focus from what you're typing in.
class MicButton extends StatelessWidget {
  const MicButton(this.d, {super.key, this.label, this.enabled = true, this.small = false});
  final Dictation d;
  final String? label;
  final bool enabled;

  /// In a text box's corner.
  final bool small;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (context, _) {
      final on = d.listening;
      return Tooltip(
        message: _title,
        child: Semantics(
          button: true,
          toggled: on,
          label: 'Dictate',
          onTap: enabled ? d.toggle : null,
          child: MouseRegion(
            cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.forbidden,
            child: Listener(
              key: const ValueKey('dictate-mic'),
              onPointerDown: enabled ? (e) => e.buttons == kPrimaryButton ? d.press() : null : null,
              onPointerUp: (_) => d.release(),
              onPointerCancel: (_) => d.release(),
              child: Container(
                padding: small
                    ? const EdgeInsets.symmetric(horizontal: 6, vertical: 2)
                    : const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: on ? Swatch.bad : Colors.white,
                  borderRadius: BorderRadius.circular(small ? 9 : 12),
                  border: Border.all(color: Swatch.ink, width: small ? 2 : kBorder),
                  boxShadow: [
                    BoxShadow(color: Swatch.ink, offset: Offset(0, small ? 2 : 2)),
                    if (on) BoxShadow(color: Swatch.bad.withValues(alpha: 0.35), spreadRadius: 5),
                  ],
                ),
                child: Opacity(
                  opacity: enabled ? 1 : 0.5,
                  child: Text(
                    label != null ? '🎤 $label' : '🎤',
                    style: heavy(small ? 15 : 14, color: on ? Colors.white : Swatch.ink),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// What it hears, as it's heard: over the bottom of the box, or of the terminal. Nothing until it listens.
class DictateLive extends StatelessWidget {
  const DictateLive(this.d, {super.key});
  final Dictation d;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: d,
    builder: (context, _) {
      final text = d.live;
      if (text == null) return const SizedBox.shrink();
      return IgnorePointer(
        child: Semantics(
          liveRegion: true,
          child: Container(
            key: const ValueKey('dictate-live'),
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 4),
            decoration: BoxDecoration(
              color: Swatch.paper2,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: Swatch.ink, width: 2),
            ),
            child: Text(text, style: heavy(13), maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
        ),
      );
    },
  );
}

/// A text box you can dictate into: [child] (the box, using [controller]) with a 🎤 in its top right
/// corner. What you say goes in where its cursor is. Where the browser can't listen, it's the box as it
/// was. [line]: a one-line box, whose words heard show above it.
class DictateField extends StatefulWidget {
  const DictateField({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
    this.line = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final Widget child;
  final bool enabled;
  final bool line;

  /// Told of the new text, as typing would be.
  final ValueChanged<String>? onChanged;

  @override
  State<DictateField> createState() => _DictateFieldState();
}

class _DictateFieldState extends State<DictateField> {
  late final Dictation? _d = canDictate ? Dictation(insert: _insert, off: () => !widget.enabled) : null;

  void _insert(String text) {
    final c = widget.controller;
    final sel = c.selection;
    final start = sel.isValid ? sel.start : c.text.length;
    final end = sel.isValid ? sel.end : start;
    final r = spliceSpoken(c.text, start, end, text);
    c.value = TextEditingValue(
      text: r.value,
      selection: TextSelection.collapsed(offset: r.caret),
    );
    widget.onChanged?.call(r.value);
  }

  @override
  void dispose() {
    _d?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = _d;
    if (d == null) return widget.child;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (_, e) => d.key(e) ? KeyEventResult.handled : KeyEventResult.ignored,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          widget.child,
          Positioned(
            top: widget.line ? 5 : 8,
            right: widget.line ? 6 : 8,
            child: MicButton(d, small: true, enabled: widget.enabled),
          ),
          Positioned(
            left: widget.line ? 0 : 10,
            right: widget.line ? 0 : 10,
            top: widget.line ? -34 : null,
            bottom: widget.line ? null : 10,
            child: Align(alignment: Alignment.centerLeft, child: DictateLive(d)),
          ),
        ],
      ),
    );
  }
}
