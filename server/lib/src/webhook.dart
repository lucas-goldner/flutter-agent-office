import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

import 'secrets.dart';

/// A worker has to stay put this long before the channel hears about it, so a flicker never posts.
const _settle = Duration(seconds: 5);

/// Slack and Discord both throttle a webhook to about one message a second.
const _gap = Duration(milliseconds: 1100);
const _timeout = Duration(seconds: 10);

/// More than this many posts waiting means a stuck channel; drop the extras instead of piling up.
const _maxBacklog = 20;

class _Saved {
  _Saved(this.url, this.by, this.at);
  final String url;
  final String by;
  final int at;
  Map<String, dynamic> toJson() => {'url': url, 'by': by, 'at': at};
}

class _Message {
  _Message({required this.kind, required this.title, this.detail, this.worker});

  /// 'needs_input', 'done' or 'test'.
  final String kind;
  final String title;
  final String? detail;
  final WorkerInfo? worker;
}

final _discordHost = RegExp(r'^(ptb\.|canary\.)?discord(app)?\.com$');

WebhookKind webhookKind(Uri url) {
  if (url.host == 'hooks.slack.com') return WebhookKind.slack;
  if (_discordHost.hasMatch(url.host) && url.path.startsWith('/api/webhooks/')) return WebhookKind.discord;
  return WebhookKind.other;
}

String _hostWithPort(Uri url) => url.hasPort ? '${url.host}:${url.port}' : url.host;

/// Where the webhook goes, without the secret part of its path: "hooks.slack.com/…/x7Qe".
String _hint(Uri url) {
  final path = url.path.replaceFirst(RegExp(r'/+$'), '');
  final tail = path.length > 4 ? path.substring(path.length - 4) : path;
  return '${_hostWithPort(url)}/…$tail';
}

/// Slack reads <, > and & as markup; escaping them keeps a worker's text from pinging <!channel>.
String _slackEscape(String s) => s.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

String _oneLine(String s, int max) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > max ? '${t.substring(0, max - 1)}…' : t;
}

/// A link the office can post to, or null (JavaScript's `new URL` would have thrown).
Uri? _parseUrl(String text) {
  final u = Uri.tryParse(text);
  if (u == null || !u.hasScheme) return null;
  if ((u.scheme == 'http' || u.scheme == 'https') && u.host.isEmpty) return null;
  return u;
}

/// The office's Slack / Discord webhook. When an agent worker starts waiting on input or finishes its
/// turn, and is still that way a few seconds later with nobody at its terminal, the channel gets a
/// line about it. Set from ⚙️ Settings (or --webhook) and kept in .agent-office/webhook.json.
class Webhook {
  /// [project] names the project a worker works on (the floor it's on), or the office without one.
  Webhook(String dataDir, this._project, this._onState, {HttpClient Function()? httpClient})
    : _path = p.join(dataDir, 'webhook.json'),
      _httpClient = httpClient ?? HttpClient.new {
    _restore();
  }

  final String Function([String? workerId]) _project;
  final void Function(NotifyState state) _onState;
  final HttpClient Function() _httpClient;
  final String _path;
  _Saved? _saved;
  String? _error;
  int? _lastSentAt;

  /// Each worker's latest state, and the alert waiting out its settle time.
  final Map<String, WorkerInfo> _latest = {};
  final Map<String, ({WorkerStatus status, Timer timer})> _pending = {};
  Future<void> _chain = Future.value();
  int _backlog = 0;

  NotifyState state() {
    final saved = _saved;
    if (saved == null) return const NotifyState();
    final url = Uri.parse(saved.url);
    return NotifyState(
      webhook: NotifyWebhook(kind: webhookKind(url), hint: _hint(url), by: saved.by, at: saved.at),
      error: _error,
      lastSentAt: _lastSentAt,
    );
  }

  /// Point the office at a new webhook ('' removes it). Returns why it can't, if it can't.
  String? set(String raw, String by) {
    final text = raw.trim();
    if (text.isEmpty) {
      _saved = null;
    } else {
      final url = _parseUrl(text);
      if (url == null) return "That isn't a link. Paste the webhook URL from Slack or Discord.";
      if (url.scheme != 'https' && url.scheme != 'http') return 'The webhook has to be an http(s) link';
      if (text.length > 2000) return 'That link is too long';
      _saved = _Saved(url.toString(), by, DateTime.now().millisecondsSinceEpoch);
    }
    _error = null;
    _lastSentAt = null;
    _persist();
    _onState(state());
    return null;
  }

  /// Called with every worker update.
  void onWorker(WorkerInfo w) {
    final prev = _latest[w.id];
    _latest[w.id] = w;
    if (w.kind != WorkerKind.agent || prev == null || prev.status == w.status) return;
    _cancel(w.id);
    if (w.status != WorkerStatus.needsInput && w.status != WorkerStatus.done) return;
    final status = w.status;
    final timer = Timer(_settle, () {
      _pending.remove(w.id);
      final cur = _latest[w.id];
      // Someone opened its terminal (or it moved on) meanwhile: they've got it.
      if (cur == null || cur.status != status || cur.acked || cur.viewers.isNotEmpty) return;
      unawaited(_alert(cur, status));
    });
    _pending[w.id] = (status: status, timer: timer);
  }

  void onWorkerGone(String id) {
    _cancel(id);
    _latest.remove(id);
  }

  /// Posts a test message. Completes with an error message if it didn't get through.
  Future<String?> test(String by) {
    if (_saved == null) return Future.value('No webhook is set');
    return _post(
      _Message(
        kind: 'test',
        title: '🔔 $by connected ${_project()} to this channel',
        detail: 'Workers that need input or finish will show up here.',
      ),
    );
  }

  void stop() {
    for (final id in [..._pending.keys]) {
      _cancel(id);
    }
  }

  void _cancel(String id) {
    final pending = _pending.remove(id);
    pending?.timer.cancel();
  }

  Future<String?> _alert(WorkerInfo w, WorkerStatus status) {
    final what = status == WorkerStatus.needsInput ? '🙋 ${w.name} needs input' : '✅ ${w.name} is done';
    final taskName = w.task?.name ?? '';
    final task = taskName.isNotEmpty ? ' — ${_oneLine(taskName, 80)}' : '';
    final detail = alertDetail(w);
    return _post(
      _Message(
        kind: status.wire,
        title: '$what in ${_project(w.id)}$task',
        detail: detail != null && detail.isNotEmpty ? _oneLine(detail, 300) : null,
        worker: w,
      ),
    );
  }

  Future<String?> _post(_Message msg) {
    final saved = _saved;
    if (saved == null) return Future.value('No webhook is set');
    if (_backlog >= _maxBacklog) return Future.value('Too many messages are waiting to be posted');
    _backlog++;
    final run = _chain.then((_) async {
      try {
        return await _send(saved, msg);
      } finally {
        _backlog--;
        await Future<void>.delayed(_gap);
      }
    });
    _chain = run.then((_) {}, onError: (_) {});
    return run;
  }

  Future<String?> _send(_Saved saved, _Message msg) async {
    final url = Uri.parse(saved.url);
    final kind = webhookKind(url);
    Object? body;
    if (kind == WebhookKind.slack) {
      body = {'text': '*${_slackEscape(msg.title)}*${msg.detail != null ? '\n>${_slackEscape(msg.detail!)}' : ''}'};
    } else if (kind == WebhookKind.discord) {
      // No @everyone or role pings, whatever a worker's text says.
      body = {
        'content': '**${msg.title}**${msg.detail != null ? '\n> ${msg.detail}' : ''}',
        'username': 'Agent Office',
        'allowed_mentions': {'parse': <String>[]},
      };
    } else {
      final w = msg.worker;
      body = {
        'text': msg.detail != null ? '${msg.title}\n${msg.detail}' : msg.title,
        'event': msg.kind,
        'project': _project(w?.id),
        'worker': ?(w == null
            ? null
            : {
                'id': w.id,
                'name': w.name,
                'desk': w.deskId,
                'status': w.status.wire,
                'task': ?w.task?.name,
                'branch': ?w.worktree?.branch,
              }),
      };
    }
    String? error;
    final client = _httpClient();
    try {
      await () async {
        final req = await client.postUrl(url);
        req.followRedirects = false;
        req.headers.contentType = ContentType.json;
        req.add(utf8.encode(jsonEncode(body)));
        final res = await req.close();
        final text = await res.transform(utf8.decoder).join().catchError((_) => '');
        if (res.isRedirect || (res.statusCode >= 300 && res.statusCode < 400)) {
          error = "Couldn't reach the webhook: unexpected redirect";
        } else if (res.statusCode < 200 || res.statusCode >= 300) {
          final why = _oneLine(text.isNotEmpty ? text : res.reasonPhrase, 120);
          error = 'The webhook answered ${res.statusCode}${why.isNotEmpty ? ': $why' : ''}';
        }
      }().timeout(_timeout);
    } on TimeoutException {
      error = 'The webhook did not answer in time';
    } catch (err) {
      final why = err is SocketException
          ? err.message.isNotEmpty
                ? err.message
                : '${err.osError?.message ?? err}'
          : err is HttpException
          ? err.message
          : '$err';
      error = "Couldn't reach the webhook: $why";
    } finally {
      client.close(force: true);
    }
    // The link was changed while this was on its way; its outcome says nothing about the new one.
    if (!identical(_saved, saved)) return error;
    if (error != null) stderr.writeln('agent-office: webhook: $error');
    if (error != _error || error == null) {
      _error = error;
      if (error == null) _lastSentAt = DateTime.now().millisecondsSinceEpoch;
      _onState(state());
    }
    return error;
  }

  void _persist() {
    try {
      writePrivateFile(_path, jsonPretty(_saved?.toJson() ?? {}));
    } catch (_) {
      // disk issues shouldn't take the office down
    }
  }

  void _restore() {
    final f = File(_path);
    if (!f.existsSync()) return;
    try {
      final s = jsonDecode(f.readAsStringSync());
      if (s is! Map) return;
      final url = s['url'];
      if (url is String && _parseUrl(url) != null) {
        final by = s['by'];
        final at = s['at'];
        _saved = _Saved(url, by is String ? by : '?', at is num ? at.toInt() : DateTime.now().millisecondsSinceEpoch);
      }
    } catch (_) {
      // a broken file just means no webhook
    }
  }
}
