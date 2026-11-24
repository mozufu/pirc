import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:markdown/markdown.dart' as md;

/// Positive CSS margins, including margins which collapse through unpadded
/// list containers. Blockquote padding stops that collapse at its inner edge.
class NativeMarkdownMargins {
  const NativeMarkdownMargins({
    required this.fontSize,
    required this.paragraphSpacing,
    required this.textScaler,
  });
  final double fontSize, paragraphSpacing;
  final TextScaler textScaler;
  double get em => textScaler.scale(fontSize);
  double get paragraph => em * paragraphSpacing / fontSize;
  double? heading(String tag) => switch (tag) {
    'h1' => textScaler.scale(fontSize * 1.35),
    'h2' => textScaler.scale(fontSize * 1.2),
    'h3' => textScaler.scale(fontSize * 1.08),
    'h4' || 'h5' || 'h6' => em,
    _ => null,
  };
  bool list(String tag) => tag == 'ul' || tag == 'ol';
  double top(md.Element node, {String? parent, bool first = false}) {
    var result = (heading(node.tag) ?? 0) * 1.3;
    if (node.tag == 'li' && !first || list(node.tag) && parent == 'li') {
      result = em * .2;
    }
    if ((list(node.tag) || node.tag == 'li') &&
        node.children?.isNotEmpty == true) {
      final child = node.children!.first;
      if (child is md.Element) {
        result = math.max(result, top(child, parent: node.tag, first: true));
      }
    }
    return result;
  }

  double bottom(md.Element node, {String? parent}) {
    final h = heading(node.tag);
    var result = h != null
        ? h * .5
        : switch (node.tag) {
            'li' || 'pirc-inline' => 0.0,
            'p' when parent == 'li' => em * .4,
            'ul' || 'ol' when parent == 'li' => 0.0,
            'p' ||
            'ul' ||
            'ol' ||
            'blockquote' ||
            'pre' ||
            'hr' ||
            'pirc-code' ||
            'pirc-table' ||
            'pirc-math-block' => paragraph,
            _ => 0.0,
          };
    if ((list(node.tag) || node.tag == 'li') &&
        node.children?.isNotEmpty == true) {
      final child = node.children!.last;
      if (child is md.Element) {
        result = math.max(result, bottom(child, parent: node.tag));
      }
    }
    return result;
  }

  // Resetting a root list's own CSS margin does not reset the margins of
  // descendants which collapse through its unpadded box.
  double startEdge(md.Element node) {
    if (!list(node.tag) || node.children?.isNotEmpty != true) return 0;
    final first = node.children!.first;
    return first is md.Element ? top(first, parent: node.tag, first: true) : 0;
  }

  double endEdge(md.Element node) {
    if (!list(node.tag) || node.children?.isNotEmpty != true) return 0;
    final last = node.children!.last;
    return last is md.Element ? bottom(last, parent: node.tag) : 0;
  }

  double gap(md.Element previous, md.Element next, {String? parent}) =>
      math.max(bottom(previous, parent: parent), top(next, parent: parent));
}
