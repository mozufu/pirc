import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:pirc_client/pirc_client.dart';

/// A versioned result inside an assistant message: a ```` ```pirc-artifact ````
/// block holding JSON (`id`, `version`, `title`, `type`, `content`,
/// `summary`, `status`). Malformed blocks stay as Markdown.
@immutable
class Artifact {
  const Artifact(this.data, this.messageId);

  final Map<String, Object?> data;
  final String messageId;

  String get id => data['id']! as String;
  int get version => data['version']! as int;
  String get title => data['title']! as String;

  /// markdown, code, table, image; anything else is shown as its summary.
  String get kind => '${data['type'] ?? 'markdown'}';
  String get content => '${data['content'] ?? ''}';
  String get summary => '${data['summary'] ?? ''}';

  /// generating, complete or failed.
  String get status => '${data['status'] ?? 'complete'}';
  bool get supported => const {'markdown', 'code', 'table'}.contains(kind);

  List<String> get columns => [
    for (final c in (data['columns'] as List?) ?? const []) '$c',
  ];
  List<List<String>> get rows => [
    for (final row in (data['rows'] as List?) ?? const [])
      if (row is List) [for (final cell in row) '$cell'],
  ];

  /// What Copy and Share give: the text, or the table as tab-separated
  /// lines.
  String get shareText => kind == 'table'
      ? [
          title,
          columns.join('\t'),
          for (final row in rows) row.join('\t'),
        ].join('\n')
      : content;
}

final _blocks = RegExp(
  r'^```pirc-artifact\s*\n([\s\S]*?)\n```\s*$',
  multiLine: true,
);

/// The valid result blocks of [message] (assistant messages only).
List<Artifact> messageArtifacts(Message message) {
  if (message.role != 'assistant') return const [];
  final found = <Artifact>[];
  for (final match in _blocks.allMatches(message.content)) {
    final body = match.group(1)!;
    if (body.length > 1024 * 1024) continue;
    try {
      final data = jsonDecode(body);
      if (data is! Map<String, Object?> ||
          data['id'] is! String ||
          (data['id']! as String).isEmpty ||
          data['title'] is! String ||
          (data['title']! as String).trim().isEmpty ||
          data['version'] is! int ||
          (data['version']! as int) < 1) {
        continue;
      }
      found.add(
        Artifact({
          ...data,
          if (message.isPartial) 'status': 'generating',
        }, message.id),
      );
    } on FormatException {
      // Shown as the original Markdown.
    }
  }
  return found;
}

/// [message]'s text without the result blocks that became cards.
String artifactProse(Message message) =>
    message.content.replaceAllMapped(_blocks, (match) {
      final probe = message.copyWith(content: match.group(0));
      return messageArtifacts(probe).isEmpty ? match.group(0)! : '';
    }).trim();

/// Every version of result [id] in [messages], oldest first. A completed
/// version is never rewritten by a later duplicate.
List<Artifact> artifactVersions(List<Message> messages, String id) {
  final versions = <int, Artifact>{};
  for (final message in messages) {
    for (final artifact in messageArtifacts(message)) {
      if (artifact.id != id) continue;
      final old = versions[artifact.version];
      if (old == null || old.status == 'generating') {
        versions[artifact.version] = artifact;
      }
    }
  }
  return versions.values.toList()
    ..sort((a, b) => a.version.compareTo(b.version));
}
