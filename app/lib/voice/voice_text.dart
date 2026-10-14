// What voice says when it can't, kept apart from the WebRTC code so it can be tested off the web.

/// A call with [name] couldn't connect at all (#244): ICE failed, direct and through any relay.
String unreachableText(String? name) =>
    "🎙️ Can't connect voice with ${name ?? 'someone'}: a network between you blocks direct calls. The office needs a TURN server (see self-hosting docs).";
