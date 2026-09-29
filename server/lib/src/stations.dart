// What the board agents are told when they're hired: the agents standing by the Issues board, the PR
// board and the task queue (stations in office_shared's layout). Whoever walks up types them a
// request; the first one follows this brief in the same prompt. The briefs themselves are prompts
// the office can rewrite in ⚙️ Settings (office_shared's prompts.dart). Port of src/server/stations.ts.

import 'package:office_shared/shared.dart';

import 'prompts.dart';

String stationBrief(StationKind kind, [PromptSource? prompts]) => officePrompt(prompts, 'station.${kind.wire}');

/// Claude Code tools the queue agent is launched without, so it can't edit the checkout even by mistake.
const List<String> queueAgentDisallowedTools = ['Edit', 'Write', 'NotebookEdit'];
