/// Merging tool updates into tool calls (part of the `pi-messages.ts` port).
library;

import 'types.dart';

/// Merge an update into a tool, keeping whatever the update does not override.
ToolCall mergeTool(ToolCall? existing, ToolUpdate update) {
  final base =
      existing ??
      ToolCall(id: update.id, name: update.name ?? 'tool', status: 'running');
  final merged = base.copyWith(
    id: update.id,
    name: update.name,
    title: update.title,
    status: update.status,
    input: update.input,
    output: update.output,
    diff: update.diff,
    images: update.images,
    startedAt: update.startedAt,
    endedAt: update.endedAt,
    recording: update.recording,
  );
  // A finished tool never regresses to running because of a stale re-send.
  return existing != null &&
          existing.status != 'running' &&
          update.status == 'running'
      ? merged.copyWith(status: existing.status)
      : merged;
}

ToolUpdate asUpdate(ToolCall tool) => ToolUpdate(
  tool.id,
  name: tool.name,
  title: tool.title,
  status: tool.status,
  input: tool.input,
  output: tool.output,
  diff: tool.diff,
  images: tool.images.isEmpty ? null : tool.images,
  startedAt: tool.startedAt,
  endedAt: tool.endedAt,
  recording: tool.recording,
);

/// Merge a `ptc` operation into its `ptc` call among [tools]; null when that
/// call is not there. Operations keep their start order.
List<ToolCall>? withOperation(
  List<ToolCall> tools,
  String parentId,
  ToolUpdate update,
) {
  if (!tools.any((it) => it.id == parentId)) return null;
  final fields = update.withoutParent();
  return [
    for (final tool in tools)
      if (tool.id != parentId)
        tool
      else
        tool.copyWith(
          operations: tool.operations.any((it) => it.id == update.id)
              ? [
                  for (final op in tool.operations)
                    op.id == update.id ? mergeTool(op, fields) : op,
                ]
              : [...tool.operations, mergeTool(null, fields)],
        ),
  ];
}
