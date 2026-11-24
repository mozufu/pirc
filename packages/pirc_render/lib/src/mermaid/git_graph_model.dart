/// Immutable GitGraph model for the bounded Mermaid 11.17.2 subset.
///
/// Commit parent IDs are the authoritative topology: ordinary commits have at
/// most one parent, merges have two, and cherry-picks link to both the current
/// branch head and the picked commit.
enum NativeGitGraphDirection { lr, tb, bt }

enum NativeGitCommitType { normal, reverse, highlight, merge, cherryPick }

class NativeGitGraphBranch {
  const NativeGitGraphBranch({
    required this.name,
    required this.order,
    required this.declarationIndex,
    required this.headId,
  });

  final String name;
  final double order;
  final int declarationIndex;
  final String? headId;
}

class NativeGitGraphCommit {
  NativeGitGraphCommit({
    required this.id,
    required this.message,
    required this.sequence,
    required this.type,
    required Iterable<String> tags,
    required Iterable<String> parents,
    required this.branch,
    this.customType,
    this.customId = false,
  }) : tags = List.unmodifiable(tags),
       parents = List.unmodifiable(parents);

  final String id;
  final String message;
  final int sequence;
  final NativeGitCommitType type;
  final List<String> tags;
  final List<String> parents;
  final String branch;

  /// The optional NORMAL/REVERSE/HIGHLIGHT override on a merge statement.
  final NativeGitCommitType? customType;

  /// Mermaid only marks explicit merge IDs this way; its renderer only shows
  /// the merge's ID label when this is true.
  final bool customId;

  NativeGitCommitType get renderedType =>
      type == NativeGitCommitType.merge ? (customType ?? type) : type;
}

class NativeGitGraphDiagram {
  NativeGitGraphDiagram({
    required this.direction,
    required Iterable<NativeGitGraphBranch> branches,
    required Iterable<NativeGitGraphCommit> commits,
    required this.currentBranch,
    this.title = '',
    this.accessibleTitle = '',
    this.accessibleDescription = '',
  }) : branches = List.unmodifiable(branches),
       commits = List.unmodifiable(commits);

  final NativeGitGraphDirection direction;
  final List<NativeGitGraphBranch> branches;
  final List<NativeGitGraphCommit> commits;
  final String currentBranch;
  final String title;
  final String accessibleTitle;
  final String accessibleDescription;

  NativeGitGraphCommit? commitById(String id) {
    for (final commit in commits) {
      if (commit.id == id) return commit;
    }
    return null;
  }

  NativeGitGraphBranch? branchByName(String name) {
    for (final branch in branches) {
      if (branch.name == name) return branch;
    }
    return null;
  }
}
