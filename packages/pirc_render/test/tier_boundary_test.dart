import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The chat library must not compile in tier-3 code (plans/client.md,
/// Rendering) and must build for Web, so nothing it reaches may import
/// `dart:io` except through a conditional import's non-default branch.
void main() {
  final reachable = _reachableLibraries('lib/pirc_render.dart');

  test('the chat library reaches no tier-3 code', () {
    final tier3 = reachable.where(
      (uri) =>
          uri.startsWith('package:pirc_render_document/') ||
          _tier3Libraries.any(uri.endsWith),
    );
    expect(tier3, isEmpty);
    expect(reachable.length, greaterThan(100), reason: 'walk found the engine');
  });

  test('the chat library builds without dart:io', () {
    expect(reachable, isNot(contains('dart:io')));
  });

  test('pirc_render does not depend on pirc_render_document', () {
    expect(
      File('pubspec.yaml').readAsStringSync(),
      isNot(contains('pirc_render_document')),
    );
  });
}

/// Script runtime, Canvas, computed-style export, the dialog top layer,
/// script callbacks and script submissions.
const _tier3Libraries = [
  '/document_canvas.dart',
  '/document_canvas_pointer.dart',
  '/document_computed_styles.dart',
  '/document_top_layer.dart',
  '/html_script_callbacks.dart',
  '/html_script_submission.dart',
];

final _directive = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// Follows imports and exports from [entry] inside this package. For a
/// conditional directive only the default URI counts (the Web build's).
Set<String> _reachableLibraries(String entry) {
  final seen = <String>{};
  final files = <String>{};
  void visit(File file) {
    if (!files.add(file.absolute.path)) return;
    for (final match in _directive.allMatches(file.readAsStringSync())) {
      final uri = match[1]!;
      if (uri.startsWith('dart:')) {
        seen.add(uri);
      } else if (uri.startsWith('package:pirc_render/')) {
        seen.add(uri);
        visit(File('lib/${uri.substring('package:pirc_render/'.length)}'));
      } else if (uri.startsWith('package:')) {
        seen.add(uri);
      } else {
        final target = File.fromUri(file.absolute.uri.resolve(uri));
        seen.add('package:pirc_render/${_libPath(target)}');
        visit(target);
      }
    }
  }

  visit(File(entry));
  return seen;
}

String _libPath(File file) {
  final lib = Directory('lib').absolute.uri.path;
  return file.absolute.uri.path.substring(lib.length);
}
