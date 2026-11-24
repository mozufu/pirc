import 'dart:math' as math;
import 'package:html/dom.dart' as dom;

/// A contribution retains the width basis of its original element even when
/// its margin collapses through multiple ancestors.
class NativeDocumentTopMarginContribution {
  const NativeDocumentTopMarginContribution({
    required this.originId,
    required this.value,
    this.percentage = false,
  });
  final String originId;
  final double value;
  final bool percentage;
}

class NativeDocumentTopMarginGroup {
  const NativeDocumentTopMarginGroup(this.contributions);
  final List<NativeDocumentTopMarginContribution> contributions;
}

/// Fixed-pixel groups keep their existing rendering path.
Map<String, double> nativeDocumentCollapsedTopMargins({
  required dom.Document document,
  required Map<dom.Element, Map<String, String>> stylesByElement,
}) =>
    _collapseTopMargins(
      document: document,
      stylesByElement: stylesByElement,
      percentages: false,
    ).map(
      (key, terms) => MapEntry(
        key,
        terms.fold<double>(0, (value, term) => math.max(value, term.value)),
      ),
    );

/// Percentage groups are resolved by the native document layout root using
/// each original element's actual containing-block width. Empty entries mark
/// members whose top margin is carried by the outermost group owner.
Map<String, NativeDocumentTopMarginGroup> nativeDocumentPercentTopMarginGroups({
  required dom.Document document,
  required Map<dom.Element, Map<String, String>> stylesByElement,
}) {
  final plan = _collapseTopMargins(
    document: document,
    stylesByElement: stylesByElement,
    percentages: true,
  );
  final result = <String, NativeDocumentTopMarginGroup>{};
  for (final entry in plan.entries) {
    if (!entry.value.any((term) => term.percentage)) continue;
    for (final term in entry.value) {
      result[term.originId] = const NativeDocumentTopMarginGroup([]);
    }
    result[entry.key] = NativeDocumentTopMarginGroup(entry.value);
  }
  return result;
}

/// Resolve only eligible, nonempty in-flow top edges from the original DOM.
/// Signed/font-relative margins, empty blocks and bottom-edge collapse still
/// need wider formatting-context support. Author/computed styles are untouched.
Map<String, List<NativeDocumentTopMarginContribution>> _collapseTopMargins({
  required dom.Document document,
  required Map<dom.Element, Map<String, String>> stylesByElement,
  required bool percentages,
}) {
  final overrides = <String, List<NativeDocumentTopMarginContribution>>{};
  final root = document.documentElement;
  if (root == null) return overrides;
  const blockTags = {
    'html',
    'body',
    'div',
    'section',
    'article',
    'header',
    'footer',
    'main',
    'nav',
    'aside',
    'address',
    'form',
    'p',
    'pre',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'dl',
    'dt',
    'dd',
  };
  const defaultMarginTags = {
    'p',
    'pre',
    'blockquote',
    'h1',
    'h2',
    'h3',
    'h4',
    'h5',
    'h6',
    'ul',
    'ol',
    'dl',
    'dd',
  };
  const metadata = {'head', 'style', 'script', 'link', 'meta', 'title', 'base'};
  Map<String, String> styles(dom.Element element) =>
      stylesByElement[element] ?? const {};
  String value(dom.Element element, String key, String fallback) =>
      (styles(element)[key] ?? fallback).trim().toLowerCase();
  String display(dom.Element element) => value(
    element,
    'display',
    metadata.contains(element.localName)
        ? 'none'
        : blockTags.contains(element.localName)
        ? 'block'
        : 'inline',
  );
  double? pixels(String source) {
    final match = RegExp(
      r'^\+?((?:[0-9]+(?:\.[0-9]+)?|\.[0-9]+))(px)?$',
    ).firstMatch(source.trim().toLowerCase());
    if (match == null) return null;
    final number = double.tryParse(match[1]!);
    return number != null &&
            number.isFinite &&
            (match[2] != null || number == 0)
        ? number
        : null;
  }

  List<NativeDocumentTopMarginContribution>? top(dom.Element element) {
    final key = element.attributes['data-pirc-document-style'];
    if (key == null) return null;
    if (overrides.containsKey(key)) return overrides[key];
    final css = styles(element);
    final source =
        css['margin-top'] ?? css['margin']?.trim().split(RegExp(r'\s+')).first;
    double? number;
    var percentage = false;
    if (source != null) {
      if (percentages && source.trim().endsWith('%')) {
        final raw = source.trim();
        number = double.tryParse(raw.substring(0, raw.length - 1));
        if (number == null || !number.isFinite || number < 0) return null;
        percentage = true;
      } else {
        number = pixels(source);
      }
    } else if (identical(element, document.body)) {
      number = 8;
    } else if (!defaultMarginTags.contains(element.localName)) {
      number = 0;
    }
    return number == null
        ? null
        : [
            NativeDocumentTopMarginContribution(
              originId: key,
              value: number,
              percentage: percentage,
            ),
          ];
  }

  bool zeroTopEdge(dom.Element element) {
    if (pixels(value(element, 'padding-top', '0')) != 0) return false;
    final borderStyle = value(element, 'border-top-style', 'none');
    return const {'none', 'hidden'}.contains(borderStyle) ||
        pixels(value(element, 'border-top-width', '3px')) == 0;
  }

  bool ordinaryBlock(dom.Element element) =>
      display(element) == 'block' &&
      !const {
        'img',
        'canvas',
        'input',
        'button',
        'textarea',
        'select',
        'video',
        'audio',
        'svg',
        'iframe',
      }.contains(element.localName) &&
      const {
        'static',
        'relative',
      }.contains(value(element, 'position', 'static')) &&
      value(element, 'float', 'none') == 'none' &&
      value(element, 'clear', 'none') == 'none' &&
      value(element, 'writing-mode', 'horizontal-tb') == 'horizontal-tb';
  bool normalWhitespace(dom.Element element) {
    dom.Element? current = element;
    while (current != null) {
      if (styles(current).containsKey('white-space')) {
        return const {
          'normal',
          'nowrap',
        }.contains(value(current, 'white-space', 'normal'));
      }
      if (current.localName == 'pre') return false;
      current = current.parent;
    }
    return true;
  }

  bool allowsChildCollapse(dom.Element element) {
    if (identical(element, root) ||
        !ordinaryBlock(element) ||
        !zeroTopEdge(element) ||
        !normalWhitespace(element)) {
      return false;
    }
    final parent = element.parent;
    if (parent != null &&
        const {
          'flex',
          'inline-flex',
          'grid',
          'inline-grid',
        }.contains(display(parent))) {
      return false;
    }
    final css = styles(element);
    final shorthand = value(
      element,
      'overflow',
      'visible',
    ).split(RegExp(r'\s+'));
    for (final side in ['x', 'y']) {
      final fallback = side == 'y' && shorthand.length > 1
          ? shorthand[1]
          : shorthand.first;
      if (!const {
        'visible',
        'clip',
      }.contains(value(element, 'overflow-$side', fallback))) {
        return false;
      }
    }
    return value(element, 'contain', 'none') == 'none' &&
        value(element, 'content-visibility', 'visible') == 'visible' &&
        value(element, 'column-count', 'auto') == 'auto' &&
        value(element, 'column-width', 'auto') == 'auto' &&
        !css.keys.any((key) => key.startsWith('margin-block'));
  }

  bool positiveHeight(dom.Element element, String property) {
    final source = value(
      element,
      property,
      property == 'height' ? 'auto' : '0',
    );
    final fixed = pixels(source);
    if (fixed != null) return fixed > 0;
    if (!source.endsWith('%')) return false;
    final percent = double.tryParse(source.substring(0, source.length - 1));
    final parent = element.parent;
    return percent != null &&
        percent.isFinite &&
        percent > 0 &&
        parent != null &&
        positiveHeight(parent, 'height');
  }

  bool hasContent(dom.Element element) {
    if (positiveHeight(element, 'height') ||
        positiveHeight(element, 'min-height')) {
      return true;
    }
    for (final node in element.nodes) {
      if (node is dom.Text && !RegExp(r'^[\t\n\r\f ]*$').hasMatch(node.text)) {
        return true;
      }
      if (node is! dom.Element || display(node) == 'none') continue;
      if (!const {
            'static',
            'relative',
          }.contains(value(node, 'position', 'static')) ||
          value(node, 'float', 'none') != 'none') {
        continue;
      }
      if (const {
            'img',
            'canvas',
            'input',
            'button',
            'textarea',
            'select',
            'video',
            'audio',
            'svg',
          }.contains(node.localName) ||
          hasContent(node)) {
        return true;
      }
    }
    return false;
  }

  dom.Element? firstChild(dom.Element element) {
    for (final node in element.nodes) {
      if (node is dom.Text && !RegExp(r'^[\t\n\r\f ]*$').hasMatch(node.text)) {
        return null;
      }
      if (node is! dom.Element || display(node) == 'none') continue;
      // Float/position/inline formatting can affect the first in-flow edge.
      return ordinaryBlock(node) ? node : null;
    }
    return null;
  }

  void visit(dom.Element element) {
    for (final child in element.children) {
      visit(child);
    }
    if (!allowsChildCollapse(element)) return;
    final child = firstChild(element);
    if (child == null || !hasContent(child)) return;
    final parentKey = element.attributes['data-pirc-document-style'];
    final childKey = child.attributes['data-pirc-document-style'];
    if (parentKey == null || childKey == null) return;
    final parentTop = top(element), childTop = top(child);
    if (parentTop == null ||
        childTop == null ||
        childTop.every((term) => term.value == 0)) {
      return;
    }
    overrides[parentKey] = [...parentTop, ...childTop];
    overrides[childKey] = [];
  }

  visit(root);
  return overrides;
}
