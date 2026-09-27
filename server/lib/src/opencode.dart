import 'dart:convert';
import 'dart:io';

import 'package:office_shared/shared.dart';
import 'package:path/path.dart' as p;

/// What the generated OpenCode plugin says a session is doing.
enum OpenCodeHookStatus implements WireEnum {
  starting('starting'),
  working('working'),
  needsInput('needs_input'),
  done('done');

  const OpenCodeHookStatus(this.wire);
  @override
  final String wire;

  static OpenCodeHookStatus? tryParse(Object? v) => parseWireOrNull(values, v);
}

/// A payload POSTed by the generated OpenCode plugin to /hooks/opencode.
sealed class OpenCodeHookEvent {
  const OpenCodeHookEvent({required this.sessionId});

  final String sessionId;

  Map<String, dynamic> toJson();
}

/// Compact, stable bridge payload sent by the generated OpenCode plugin.
class OpenCodeStatusEvent extends OpenCodeHookEvent {
  const OpenCodeStatusEvent({
    required this.type,
    required super.sessionId,
    required this.status,
    this.prompt,
    this.tool,
    this.detail,
  });

  /// 'session', 'prompt', 'tool', 'permission', 'question' or 'error'.
  final String type;
  final OpenCodeHookStatus status;
  final String? prompt;
  final String? tool;
  final String? detail;

  static const types = {'session', 'prompt', 'tool', 'permission', 'question', 'error'};

  @override
  Map<String, dynamic> toJson() => {
    'type': type,
    'sessionId': sessionId,
    'status': status.wire,
    'prompt': ?prompt,
    'tool': ?tool,
    'detail': ?detail,
  };
}

class OpenCodeUsageEvent extends OpenCodeHookEvent {
  const OpenCodeUsageEvent({required super.sessionId, required this.usage});

  final Usage usage;

  @override
  Map<String, dynamic> toJson() => {'type': 'usage', 'sessionId': sessionId, 'usage': usage.toJson()};
}

/// Merge the per-process plugin into inline OpenCode config without touching user config files.
/// Throws a [FormatException] when [existing] is not a JSON object with an array `plugin`.
String mergeOpenCodeConfigContent(String? existing, String plugin) {
  var config = <String, dynamic>{};
  if (existing != null && existing.isNotEmpty) {
    try {
      final parsed = jsonDecode(existing);
      if (parsed is! Map) throw const FormatException('not an object');
      config = Map<String, dynamic>.from(parsed);
      if (config['plugin'] != null && config['plugin'] is! List) throw const FormatException('plugin is not an array');
    } catch (_) {
      throw const FormatException('OPENCODE_CONFIG_CONTENT must be valid JSON');
    }
  }
  final current = config['plugin'];
  final plugins = current is List ? [...current] : <Object?>[];
  if (!plugins.contains(plugin)) plugins.add(plugin);
  config['plugin'] = plugins;
  return jsonEncode(config);
}

/// Write the self-contained plugin used for every OpenCode worker process.
String writeOpenCodePlugin(String dataDir) {
  Directory(dataDir).createSync(recursive: true);
  _chmod('700', dataDir);
  final file = p.join(dataDir, 'agent-office-opencode.mjs');
  File(file).writeAsStringSync(openCodePluginSource);
  _chmod('600', file);
  return file;
}

void _chmod(String mode, String path) {
  if (Platform.isWindows) return;
  try {
    Process.runSync('chmod', [mode, path]);
  } catch (_) {
    // Best effort, as Node's mode option is on filesystems that ignore it.
  }
}

String openCodePluginSpecifier(String file) => Uri.file(p.absolute(file)).toString();

/// No imports: OpenCode loads this module from the office data directory in packaged installs.
/// It is JavaScript because OpenCode only loads JS plugins, run by its own runtime.
const openCodePluginSource = r'''export default async function AgentOfficeOpenCodePlugin({ client } = {}) {
  const url = process.env.AGENT_OFFICE_HOOK_URL;
  const token = process.env.AGENT_OFFICE_HOOK_TOKEN;
  const worker = process.env.AGENT_OFFICE_WORKER_ID;
  if (!url || !token || !worker) return {};
  let rootSession = process.env.AGENT_OFFICE_SESSION_ID || undefined;
  const children = new Set();
  const pending = new Set();
  const usageByMessage = new Map();
  const liveUsageMessages = new Set();
  const removedUsageMessages = new Set();
  let hydrationPending = false;
  let hydrationIncomplete = false;
  let usageEpoch = 0;
  let queued = Promise.resolve();

  // SDK lookups, session selection and delivery share one order. A slow selection cannot let
  // a later idle event overtake its prompt, and a stalled office cannot stall the agent forever.
  function enqueue(job) {
    queued = queued.then(job).catch(() => {});
    return queued;
  }
  async function send(value) {
    if (!value) return;
    try {
      await fetch(url + "/hooks/opencode?worker=" + encodeURIComponent(worker), {
        method: "POST",
        headers: { authorization: "Bearer " + token, "content-type": "application/json" },
        body: JSON.stringify(value),
        signal: AbortSignal.timeout(2500),
      });
    } catch {}
  }
  function detail(value) {
    return typeof value === "string" && value.trim() ? value.trim().slice(0, 500) : undefined;
  }
  function count(value) {
    return Number.isSafeInteger(value) && value >= 0 ? value : 0;
  }
  function assistantUsage(info) {
    if (!info || info.role !== "assistant" || typeof info.id !== "string" || !info.id) return;
    const tokens = info.tokens || {};
    const cache = tokens.cache || {};
    const costKnown = typeof info.cost === "number" && Number.isFinite(info.cost) && info.cost >= 0;
    return {
      input: count(tokens.input),
      output: count(tokens.output),
      ...(tokens.reasoning === undefined ? {} : { reasoning: count(tokens.reasoning) }),
      cacheRead: count(cache.read),
      cacheWrite: count(cache.write),
      cost: costKnown ? info.cost : 0,
      calls: 1,
      costKnown,
    };
  }
  function usageEvent() {
    let input = 0, output = 0, reasoning = 0, cacheRead = 0, cacheWrite = 0, cost = 0, calls = 0;
    let hasReasoning = false, costKnown = true;
    for (const entry of usageByMessage.values()) {
      if (entry.sessionId !== rootSession && !children.has(entry.sessionId)) continue;
      const usage = entry.usage;
      input += usage.input;
      output += usage.output;
      if (usage.reasoning !== undefined) { reasoning += usage.reasoning; hasReasoning = true; }
      cacheRead += usage.cacheRead;
      cacheWrite += usage.cacheWrite;
      cost += usage.cost;
      calls += usage.calls;
      if (usage.costKnown === false) costKnown = false;
    }
    return { type: "usage", sessionId: rootSession, usage: {
      input, output,
      ...(hasReasoning ? { reasoning } : {}),
      cacheRead, cacheWrite, cost, calls, costKnown,
      ...(hydrationPending || hydrationIncomplete ? { incomplete: true } : {}),
    } };
  }
  function sdkCall(fn) {
    try {
      return Promise.resolve(fn()).then((data) => ({ ok: !!data && !data.error && Array.isArray(data.data), data }), () => ({ ok: false, data: undefined }));
    } catch { return Promise.resolve({ ok: false, data: undefined }); }
  }
  async function hydrate(id, epoch) {
    if (!client || !client.session || typeof client.session.messages !== "function") return;
    const queue = [id];
    const seen = new Set();
    let changed = false;
    let incomplete = false;
    while (queue.length && seen.size < 128) {
      const sessionId = queue.shift();
      if (typeof sessionId !== "string" || seen.has(sessionId)) continue;
      seen.add(sessionId);
      const signal = AbortSignal.timeout(2500);
      // The SDK has no cursor/offset for this endpoint; omitting limit avoids silently dropping
      // older assistant messages when OpenCode's server changes its default page size.
      const messagesPromise = sdkCall(() => client.session.messages({ path: { id: sessionId }, signal }));
      const childrenPromise = typeof client.session.children === "function"
        ? sdkCall(() => client.session.children({ path: { id: sessionId }, signal }))
        : Promise.resolve({ ok: false, data: undefined });
      const [messagesResult, descendantsResult] = await Promise.all([messagesPromise, childrenPromise]);
      if (epoch !== usageEpoch || rootSession !== id) return;
      if (!messagesResult.ok || !descendantsResult.ok) incomplete = true;
      const messages = messagesResult.data;
      const descendants = descendantsResult.data;
      const childRows = descendants && Array.isArray(descendants.data) ? descendants.data : [];
      for (const child of childRows) {
        if (!child || typeof child.id !== "string" || child.id === id) continue;
        if (typeof child.parentID === "string" && child.parentID !== sessionId) continue;
        children.add(child.id);
        queue.push(child.id);
      }
      const rows = messages && Array.isArray(messages.data) ? messages.data : [];
      for (const row of rows) {
        const info = row && row.info;
        const usage = assistantUsage(info);
        if (!usage || liveUsageMessages.has(info.id) || removedUsageMessages.has(info.id)) continue;
        usageByMessage.set(info.id, { sessionId, usage });
        changed = true;
      }
    }
    if (queue.length) incomplete = true;
    if (epoch !== usageEpoch || rootSession !== id) return;
    hydrationPending = false;
    hydrationIncomplete = incomplete;
    if (changed || usageByMessage.size > 0) {
      await enqueue(() => {
        if (epoch !== usageEpoch || rootSession !== id) return;
        return send(usageEvent());
      });
    }
  }
  function select(id) {
    if (rootSession === id) return { type: "session", sessionId: id, status: "starting" };
    rootSession = id;
    usageEpoch++;
    children.clear();
    usageByMessage.clear();
    liveUsageMessages.clear();
    removedUsageMessages.clear();
    hydrationPending = !!(client && client.session && typeof client.session.messages === "function");
    hydrationIncomplete = false;
    pending.clear();
    void hydrate(id, usageEpoch);
    return { type: "session", sessionId: id, status: "starting" };
  }
  async function selectExisting(id) {
    if (id === rootSession) return true;
    if (children.has(id) || !client || !client.session) return false;
    try {
      const result = await client.session.get({ path: { id }, signal: AbortSignal.timeout(2500) });
      const info = result.data;
      if (!info || info.id !== id) return false;
      if (info.parentID) {
        if (info.parentID === rootSession || children.has(info.parentID)) children.add(id);
        return false;
      }
      await send(select(id));
      return true;
    } catch { return false; }
  }
  function compact(event) {
    if (!event || typeof event.type !== "string") return;
    const p = event.properties || {};
    const info = p.info || {};
    const id = p.sessionID || info.sessionID || info.id;
    if (event.type === "session.created") {
      if (typeof id !== "string") return;
      if (info.parentID) {
        if (info.parentID === rootSession || children.has(info.parentID)) children.add(id);
        return;
      }
      return select(id);
    }
    if (!id || (id !== rootSession && !children.has(id))) return;
    if (event.type === "message.updated") {
      const usage = assistantUsage(info);
      if (!usage) return;
      liveUsageMessages.add(info.id);
      removedUsageMessages.delete(info.id);
      usageByMessage.set(info.id, { sessionId: id, usage });
      return usageEvent();
    }
    if (event.type === "message.removed") {
      const messageId = typeof p.messageID === "string" ? p.messageID : info.id;
      if (typeof messageId !== "string") return;
      const removed = usageByMessage.delete(messageId);
      liveUsageMessages.delete(messageId);
      removedUsageMessages.add(messageId);
      if (!removed) return;
      return usageEvent();
    }
    if (id !== rootSession) return;
    const base = { type: "session", sessionId: id };
    const working = () => ({ ...base, status: pending.size ? "needs_input" : "working" });
    if (event.type === "session.status" && (p.status?.type === "busy" || p.status?.type === "retry")) return working();
    if (event.type === "session.idle" || (event.type === "session.status" && p.status?.type === "idle")) {
      pending.clear();
      return { ...base, status: "done" };
    }
    if (event.type === "session.error") {
      const err = p.error || {};
      return { ...base, type: "error", status: "needs_input", detail: detail(err.data?.message) || detail(err.message) || detail(err.name) };
    }
    if (event.type === "permission.asked" || event.type === "question.asked") {
      const kind = event.type.split(".")[0];
      pending.add(kind + ":" + p.id);
      const q = Array.isArray(p.questions) ? p.questions[0] : undefined;
      return { ...base, type: kind, status: "needs_input", detail: detail(q?.question || q?.header || p.title || p.permission) };
    }
    if (["permission.replied", "question.replied", "question.rejected"].includes(event.type)) {
      pending.delete(event.type.split(".")[0] + ":" + p.requestID);
      return working();
    }
  }
  if (rootSession && client && client.session && typeof client.session.messages === "function") {
    hydrationPending = true;
    void hydrate(rootSession, usageEpoch);
  }
  return {
    event: ({ event }) => enqueue(() => send(compact(event))),
    "chat.message": (input, output) => enqueue(async () => {
      if (typeof input.sessionID !== "string" || !await selectExisting(input.sessionID)) return;
      const parts = output && Array.isArray(output.parts) ? output.parts : [];
      const prompt = parts.filter((part) => part && part.type === "text" && typeof part.text === "string").map((part) => part.text).join("\n").trim().slice(0, 20000);
      await send({ type: "prompt", sessionId: input.sessionID, status: "working", ...(prompt ? { prompt } : {}) });
    }),
    "tool.execute.before": (input) => enqueue(() => {
      if (input.sessionID === rootSession && !children.has(input.sessionID)) {
        return send({ type: "tool", sessionId: input.sessionID, tool: input.tool, status: pending.size ? "needs_input" : "working" });
      }
    }),
  };
}
''';
