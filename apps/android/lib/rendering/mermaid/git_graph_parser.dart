import '../render_l10n.dart';
import 'dart:convert';
import 'dart:math';

import 'git_graph_model.dart';

const _gitIdAlphabet =
    '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';

/// Parses Mermaid 11.17.2 gitGraph statements and folds them with the pinned
/// DB rules for branch heads, commit parents, merge commits and cherry-picks.
///
/// Init directives/options are rejected. Generated IDs follow Mermaid's
/// sequence-plus-seven-character shape and remain stable across reparses of
/// the same source so widget rebuilds do not change commit labels.
NativeGitGraphDiagram parseNativeMermaidGitGraph(
  String source, {
  Random? random,
}) {
  if (source.length > 50000) {
    throw FormatException(
      tr("GitGraph exceeds the default 50000 character limit."),
    );
  }
  final rng = random ?? Random(source.hashCode);
  var direction = NativeGitGraphDirection.lr;
  var title = '';
  var accessibleTitle = '';
  var accessibleDescription = '';
  var headerSeen = false;
  var sequence = 0;
  var currentBranch = 'main';
  String? headId;

  final branchOrders = <String, double>{'main': 0};
  final branchDeclarationOrder = <String, int>{'main': 0};
  final branchHeads = <String, String?>{'main': null};
  final commits = <String, NativeGitGraphCommit>{};

  String makeId(int seq) {
    final suffix = List.generate(
      7,
      (_) => _gitIdAlphabet[rng.nextInt(_gitIdAlphabet.length)],
    ).join();
    return '$seq-$suffix';
  }

  NativeGitCommitType parseType(String value) => switch (value.toUpperCase()) {
    'NORMAL' => NativeGitCommitType.normal,
    'REVERSE' => NativeGitCommitType.reverse,
    'HIGHLIGHT' => NativeGitCommitType.highlight,
    _ => throw FormatException(
      tr("Unsupported gitGraph commit type: {0}", [value]),
    ),
  };

  void appendCommit({
    String? id,
    String message = '',
    NativeGitCommitType type = NativeGitCommitType.normal,
    List<String> tags = const [],
    List<String>? parents,
    NativeGitCommitType? customType,
    bool customId = false,
  }) {
    final commitId = id ?? makeId(sequence);
    if (commits.containsKey(commitId)) {
      throw FormatException(tr("Commit ID already exists: {0}", [commitId]));
    }
    final commit = NativeGitGraphCommit(
      id: commitId,
      message: message,
      sequence: sequence,
      type: type,
      tags: tags,
      parents: parents ?? (headId == null ? const [] : [headId!]),
      branch: currentBranch,
      customType: customType,
      customId: customId,
    );
    sequence++;
    commits[commitId] = commit;
    headId = commitId;
    branchHeads[currentBranch] = commitId;
  }

  final lines = source
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n');
  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final lineNumber = lineIndex + 1;
    if (lines[lineIndex].trimLeft().startsWith('%%{')) {
      throw FormatException(
        tr("GitGraph init directives are not supported (line {0}).", [
          lineNumber,
        ]),
      );
    }
    final line = _withoutComment(lines[lineIndex]).trim();
    if (line.isEmpty) continue;
    if (line.startsWith('%%{')) {
      throw FormatException(
        tr("GitGraph init directives are not supported (line {0}).", [
          lineNumber,
        ]),
      );
    }

    if (!headerSeen) {
      final header = RegExp(
        r'^gitGraph(?:(?:\s+(LR|TB|BT))?\s*:)?$',
        caseSensitive: false,
      ).firstMatch(line);
      if (header == null) {
        throw FormatException(
          tr("Expected a gitGraph header (line {0}).", [lineNumber]),
        );
      }
      final dir = header.group(1)?.toUpperCase();
      direction = switch (dir) {
        'TB' => NativeGitGraphDirection.tb,
        'BT' => NativeGitGraphDirection.bt,
        _ => NativeGitGraphDirection.lr,
      };
      headerSeen = true;
      continue;
    }

    for (final statement in _splitStatements(line)) {
      final text = statement.trim();
      if (text.isEmpty) continue;
      if (text.startsWith('%%{')) {
        throw FormatException(
          tr("GitGraph init directives are not supported (line {0}).", [
            lineNumber,
          ]),
        );
      }
      if (text.startsWith('%%')) continue;

      final titleMatch = RegExp(
        r'^title\s*:?\s*(.*)$',
        caseSensitive: false,
      ).firstMatch(text);
      if (titleMatch != null) {
        title = titleMatch.group(1)!.trim();
        continue;
      }
      final accTitleMatch = RegExp(
        r'^accTitle\s*:\s*(.*)$',
        caseSensitive: false,
      ).firstMatch(text);
      if (accTitleMatch != null) {
        accessibleTitle = accTitleMatch.group(1)!.trim();
        continue;
      }
      final accDescriptionMatch = RegExp(
        r'^accDescr\s*:\s*(.*)$',
        caseSensitive: false,
      ).firstMatch(text);
      if (accDescriptionMatch != null) {
        accessibleDescription = accDescriptionMatch.group(1)!.trim();
        continue;
      }
      if (RegExp(r'^accDescr\s*\{', caseSensitive: false).hasMatch(text)) {
        throw FormatException(
          tr("Block-form accDescr is not supported (line {0}).", [lineNumber]),
        );
      }

      final tokens = _tokens(text);
      if (tokens.isEmpty) continue;
      final command = tokens.first.toLowerCase();
      final rest = tokens.skip(1).toList(growable: false);

      switch (command) {
        case 'commit':
          final options = _options(rest, const {'id', 'msg', 'tag', 'type'});
          appendCommit(
            id: _single(options, 'id'),
            message: _single(options, 'msg') ?? '',
            type: parseType(_single(options, 'type') ?? 'NORMAL'),
            tags: options['tag'] ?? const [],
          );
          break;
        case 'branch':
          if (rest.isEmpty || rest.first.contains(':')) {
            throw _lineError(lineNumber, 'Expected branch name.');
          }
          final name = rest.first;
          final options = _options(rest.skip(1).toList(), const {'order'});
          if (branchHeads.containsKey(name)) {
            throw _lineError(lineNumber, 'Branch already exists: $name');
          }
          final rawOrder = _single(options, 'order');
          final order = rawOrder == null
              ? 0.0
              : double.tryParse(rawOrder) ??
                    (throw _lineError(lineNumber, 'Invalid branch order.'));
          branchHeads[name] = headId;
          branchOrders[name] = order;
          branchDeclarationOrder[name] = branchDeclarationOrder.length;
          currentBranch = name;
          headId = branchHeads[name];
          break;
        case 'checkout':
        case 'switch':
          if (rest.length != 1 || rest.first.contains(':')) {
            throw _lineError(lineNumber, 'Expected one branch name.');
          }
          final name = rest.single;
          if (!branchHeads.containsKey(name)) {
            throw _lineError(lineNumber, 'Branch does not exist: $name');
          }
          currentBranch = name;
          headId = branchHeads[name];
          break;
        case 'merge':
          if (rest.isEmpty || rest.first.contains(':')) {
            throw _lineError(lineNumber, 'Expected branch name to merge.');
          }
          final otherName = rest.first;
          final options = _options(rest.skip(1).toList(), const {
            'id',
            'tag',
            'type',
          });
          if (otherName == currentBranch) {
            throw _lineError(lineNumber, 'Cannot merge a branch into itself.');
          }
          final ownHead = branchHeads[currentBranch];
          final otherHead = branchHeads[otherName];
          if (ownHead == null) {
            throw _lineError(lineNumber, 'Current branch has no commits.');
          }
          if (!branchHeads.containsKey(otherName)) {
            throw _lineError(lineNumber, 'Branch does not exist: $otherName');
          }
          if (otherHead == null) {
            throw _lineError(lineNumber, 'Branch has no commits: $otherName');
          }
          if (ownHead == otherHead) {
            throw _lineError(lineNumber, 'Both branches have the same head.');
          }
          final id = _single(options, 'id');
          if (id != null && commits.containsKey(id)) {
            throw _lineError(lineNumber, 'Commit ID already exists: $id');
          }
          appendCommit(
            id: id,
            message: 'merged branch $otherName into $currentBranch',
            type: NativeGitCommitType.merge,
            customType: _single(options, 'type') == null
                ? null
                : parseType(_single(options, 'type')!),
            tags: options['tag'] ?? const [],
            parents: [ownHead, otherHead],
            customId: id != null,
          );
          break;
        case 'cherry-pick':
          final options = _options(rest, const {'id', 'tag', 'parent'});
          final sourceId = _single(options, 'id');
          if (sourceId == null || sourceId.isEmpty) {
            throw _lineError(
              lineNumber,
              'Cherry-pick requires an existing id.',
            );
          }
          final sourceCommit = commits[sourceId];
          if (sourceCommit == null) {
            throw _lineError(lineNumber, 'Cherry-pick source does not exist.');
          }
          final parent = _single(options, 'parent');
          if (parent != null && !sourceCommit.parents.contains(parent)) {
            throw _lineError(
              lineNumber,
              'Parent is not an immediate source parent.',
            );
          }
          if (sourceCommit.type == NativeGitCommitType.merge &&
              parent == null) {
            throw _lineError(
              lineNumber,
              'Cherry-picking a merge commit requires parent:.',
            );
          }
          if (sourceCommit.branch == currentBranch) {
            throw _lineError(
              lineNumber,
              'Cannot cherry-pick a commit already on the current branch.',
            );
          }
          if (headId == null) {
            throw _lineError(lineNumber, 'Current branch has no commits.');
          }
          final suppliedTags = options['tag'];
          final tags = suppliedTags == null
              ? [
                  'cherry-pick:${sourceCommit.id}'
                      '${sourceCommit.type == NativeGitCommitType.merge ? '|parent:$parent' : ''}',
                ]
              : suppliedTags.where((tag) => tag.isNotEmpty).toList();
          appendCommit(
            message:
                'cherry-picked ${sourceCommit.message} into $currentBranch',
            type: NativeGitCommitType.cherryPick,
            tags: tags,
            parents: [headId!, sourceCommit.id],
          );
          break;
        default:
          throw _lineError(
            lineNumber,
            tr("Unsupported gitGraph command: {0}", [command]),
          );
      }

      if (commits.length > 1000) {
        throw _lineError(lineNumber, tr("GitGraph exceeds 1000 commits."));
      }
    }
  }

  if (!headerSeen) {
    throw FormatException(tr("Missing gitGraph header."));
  }
  final sortedBranches = branchHeads.keys.toList()
    ..sort((a, b) {
      final order = branchOrders[a]!.compareTo(branchOrders[b]!);
      if (order != 0) return order;
      return branchDeclarationOrder[a]!.compareTo(branchDeclarationOrder[b]!);
    });
  return NativeGitGraphDiagram(
    direction: direction,
    branches: [
      for (final name in sortedBranches)
        NativeGitGraphBranch(
          name: name,
          order: branchOrders[name]!,
          declarationIndex: branchDeclarationOrder[name]!,
          headId: branchHeads[name],
        ),
    ],
    commits: commits.values.toList(),
    currentBranch: currentBranch,
    title: title,
    accessibleTitle: accessibleTitle,
    accessibleDescription: accessibleDescription,
  );
}

FormatException _lineError(int line, String message) =>
    FormatException(tr("{0} (line {1}).", [message, line]));

String _withoutComment(String input) {
  var quote = '';
  var escaped = false;
  for (var index = 0; index < input.length; index++) {
    final char = input[index];
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (input.startsWith('%%', index)) {
      return input.substring(0, index);
    }
  }
  return input;
}

List<String> _splitStatements(String input) {
  final statements = <String>[];
  var quote = '';
  var escaped = false;
  var start = 0;
  for (var index = 0; index < input.length; index++) {
    final char = input[index];
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
    } else if (char == ';') {
      statements.add(input.substring(start, index));
      start = index + 1;
    }
  }
  statements.add(input.substring(start));
  return statements;
}

List<String> _tokens(String input) {
  final tokens = <String>[];
  var index = 0;
  while (index < input.length) {
    while (index < input.length && input[index].trim().isEmpty) {
      index++;
    }
    if (index == input.length) break;
    final char = input[index];
    if (char == '"' || char == "'") {
      final quote = char;
      final start = index++;
      var escaped = false;
      while (index < input.length) {
        final current = input[index++];
        if (escaped) {
          escaped = false;
        } else if (current == r'\') {
          escaped = true;
        } else if (current == quote) {
          break;
        }
      }
      final raw = input.substring(start, index);
      if (raw.length < 2 || raw[raw.length - 1] != quote) {
        throw FormatException(tr("Unclosed quoted gitGraph value."));
      }
      tokens.add(_decodeQuoted(raw));
      continue;
    }
    final start = index;
    while (index < input.length &&
        input[index].trim().isNotEmpty &&
        input[index] != '"' &&
        input[index] != "'") {
      index++;
    }
    final fragment = input.substring(start, index);
    if (fragment.isNotEmpty) tokens.add(fragment);
  }
  return tokens;
}

String _decodeQuoted(String value) {
  if (value.startsWith('"')) {
    try {
      return jsonDecode(value) as String;
    } on FormatException {
      throw FormatException(tr("Invalid quoted gitGraph string."));
    }
  }
  final inner = value.substring(1, value.length - 1);
  return inner.replaceAll(r"\'", "'").replaceAll(r'\\', r'\');
}

Map<String, List<String>> _options(List<String> tokens, Set<String> allowed) {
  final result = <String, List<String>>{};
  for (var index = 0; index < tokens.length; index++) {
    final token = tokens[index];
    final separator = token.indexOf(':');
    if (separator < 1) {
      throw FormatException(
        tr("Expected a gitGraph option, got: {0}", [token]),
      );
    }
    final key = token.substring(0, separator).toLowerCase();
    if (!allowed.contains(key)) {
      throw FormatException(tr("Unsupported gitGraph option: {0}", [key]));
    }
    var value = token.substring(separator + 1);
    if (value.isEmpty) {
      index++;
      if (index >= tokens.length) {
        throw FormatException(
          tr("Missing value for gitGraph option: {0}", [key]),
        );
      }
      value = tokens[index];
    }
    result.putIfAbsent(key, () => <String>[]).add(value);
  }
  return result;
}

String? _single(Map<String, List<String>> options, String key) {
  final values = options[key];
  if (values == null) return null;
  if (values.length != 1) {
    throw FormatException(tr("GitGraph option repeated: {0}", [key]));
  }
  return values.single;
}
