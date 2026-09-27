import 'package:agent_office_server/src/agents.dart';
import 'package:office_shared/shared.dart';
import 'package:test/test.dart';

void main() {
  test('detects the configured provider from Unix and Windows command paths', () {
    expect(configuredProvider('claude'), AgentProvider.claude);
    expect(configuredProvider('/opt/tools/claude'), AgentProvider.claude);
    expect(configuredProvider(r'C:\Users\me\bin\opencode.exe'), AgentProvider.opencode);
    expect(configuredProvider('/opt/tools/codex'), AgentProvider.codex);
    expect(configuredProvider('CODEX.EXE'), AgentProvider.codex);
    expect(configuredProvider('my-agent'), AgentProvider.custom);
  });
}
