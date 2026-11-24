import 'package:html/dom.dart' as dom;

/// Elements with no CSS box in the currently published document snapshot.
/// Only a closed details element's first summary subtree participates. Retained
/// offstage RenderBoxes must not be exposed as visible CSS geometry.
Set<String> nativeDocumentNoBoxIds({
  required dom.Document document,
  required Iterable<String> knownIds,
  required Map<dom.Element, Map<String, String>> stylesByElement,
}) {
  final elements = document.querySelectorAll('*');
  final renderedIds = elements
      .map((e) => e.attributes['data-pirc-script-id'])
      .whereType<String>()
      .toSet();
  final result = knownIds.toSet().difference(renderedIds);
  for (final element in elements) {
    final id = element.attributes['data-pirc-script-id'];
    if (id == null) continue;
    var hidden = false;
    dom.Element? branch;
    for (var ancestor = element; ;) {
      if (stylesByElement[ancestor]?['display'] == 'none' ||
          ancestor.attributes.containsKey('hidden') ||
          const {
            'head',
            'script',
            'style',
            'title',
            'meta',
            'base',
            'link',
          }.contains(ancestor.localName) ||
          ancestor.localName == 'input' &&
              ancestor.attributes['type']?.toLowerCase() == 'hidden') {
        hidden = true;
        break;
      }
      if (ancestor.localName == 'details' &&
          ancestor != element &&
          !ancestor.attributes.containsKey('open')) {
        final summary = ancestor.children
            .where((e) => e.localName == 'summary')
            .firstOrNull;
        if (summary == null || !identical(summary, branch)) {
          hidden = true;
          break;
        }
      }
      final parent = ancestor.parent;
      if (parent == null) break;
      branch = ancestor;
      ancestor = parent;
    }
    if (hidden || stylesByElement[element]?['display'] == 'contents') {
      result.add(id);
    }
  }
  return result;
}
