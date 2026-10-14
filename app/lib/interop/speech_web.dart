// The Web Speech API's SpeechRecognition (Chrome and Safari still call it webkitSpeechRecognition).

import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../ui/speech_logic.dart';

JSFunction? _ctor() {
  final g = globalContext;
  final c = g['SpeechRecognition'] ?? g['webkitSpeechRecognition'];
  return c.isA<JSFunction>() ? c as JSFunction : null;
}

RecognizerFactory? recognizer() => _ctor() == null ? null : _WebRecognizer.new;

bool secureContext() => web.window.isSecureContext;

String language() {
  final l = web.window.navigator.language;
  return l.isEmpty ? 'en-US' : l;
}

bool android() => RegExp('Android', caseSensitive: false).hasMatch(web.window.navigator.userAgent);

Future<bool> Function(String lang)? onDevice() {
  final c = _ctor();
  if (c == null || !c.has('available')) return null;
  return (lang) async {
    final opts = JSObject()
      ..['langs'] = [lang.toJS].toJS
      ..['processLocally'] = true.toJS;
    final p = c.callMethod<JSPromise<JSString>>('available'.toJS, opts);
    return (await p.toDart).toDart == 'available';
  };
}

class _WebRecognizer extends Recognizer {
  _WebRecognizer() : _rec = _ctor()!.callAsConstructor<JSObject>();

  final JSObject _rec;
  bool _wired = false;

  void _wire() {
    if (_wired) return;
    _wired = true;
    _rec['onresult'] = ((JSObject e) {
      final list = e['results'] as JSObject;
      final n = (list['length'] as JSNumber).toDartInt;
      final out = <RecResult>[];
      for (var i = 0; i < n; i++) {
        final r = list[i.toString()] as JSObject;
        final alt = r['0'] as JSObject?;
        out.add((
          transcript: (alt?['transcript'] as JSString?)?.toDart ?? '',
          isFinal: (r['isFinal'] as JSBoolean?)?.toDart ?? false,
        ));
      }
      onresult?.call(out);
    }).toJS;
    _rec['onerror'] = ((JSObject e) => onerror?.call((e['error'] as JSString?)?.toDart ?? 'unknown')).toJS;
    _rec['onend'] = (() => onend?.call()).toJS;
  }

  @override
  void start() {
    _rec
      ..['lang'] = lang.toJS
      ..['continuous'] = continuous.toJS
      ..['interimResults'] = interimResults.toJS;
    if (processLocally) _rec['processLocally'] = true.toJS;
    _wire();
    try {
      _rec.callMethod<JSAny?>('start'.toJS);
    } catch (e) {
      throw RecognizerError('$e'.replaceFirst(RegExp(r'^\w*(Error|Exception): '), ''));
    }
  }

  @override
  void stop() => _rec.callMethod<JSAny?>('stop'.toJS);

  @override
  void abort() => _rec.callMethod<JSAny?>('abort'.toJS);
}
