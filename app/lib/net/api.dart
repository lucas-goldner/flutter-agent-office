// The office's HTTP API. Same-origin, so the browser sends the session cookie by itself.

import 'dart:convert';

import 'package:http/http.dart' as http;

class ApiResult {
  ApiResult(this.status, this.body);
  final int status;
  final Map<String, dynamic> body;
  bool get ok => status >= 200 && status < 300;

  /// The server's own words for what went wrong, or [fallback].
  String error(String fallback) => (body['error'] as String?) ?? fallback;
}

class Api {
  Api._();

  static final http.Client _client = http.Client();

  static Future<ApiResult> getJson(String path) async {
    final res = await _client.get(Uri.parse(path), headers: {'cache-control': 'no-store'});
    return ApiResult(res.statusCode, _decode(res.body));
  }

  static Future<ApiResult> postJson(String path, Map<String, dynamic> body) async {
    final res = await _client.post(
      Uri.parse(path),
      headers: {'content-type': 'application/json'},
      body: jsonEncode(body),
    );
    return ApiResult(res.statusCode, _decode(res.body));
  }

  static Future<String?> getText(String path) async {
    final res = await _client.get(Uri.parse(path));
    return res.statusCode == 200 ? res.body : null;
  }

  static Map<String, dynamic> _decode(String s) {
    try {
      final v = jsonDecode(s);
      return v is Map<String, dynamic> ? v : {'value': v};
    } catch (_) {
      return {};
    }
  }

  /// Who the session belongs to, or null when signed out (401).
  static Future<Map<String, dynamic>?> whoami() async {
    final r = await getJson('/api/whoami');
    return r.status == 401 ? null : r.body;
  }
}
