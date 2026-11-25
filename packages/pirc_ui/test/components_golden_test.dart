@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/fonts.dart';
import 'support/gallery.dart';

/// Components that run edge to edge on a phone; the others get the 16
/// gutter.
const _fullWidth = {'ChatRow', 'LogRow', 'PovBar', 'ProfileHeader', 'Stats'};

void main() {
  setUpAll(loadGoldenFonts);

  for (final brightness in Brightness.values) {
    final mode = brightness.name;
    testWidgets('components at phone width, $mode', (tester) async {
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(375 * 2, 2400 * 2);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(375, 2400),
            devicePixelRatio: 2,
            disableAnimations: true,
          ),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: PircTheme.of(brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Builder(
                  builder: (context) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final (name, widget) in Samples.sections(context))
                        RepaintBoundary(
                          key: ValueKey(name),
                          child: ColoredBox(
                            color: PircColorTokens.of(context)['surface.page'],
                            child: Padding(
                              padding: _fullWidth.contains(name)
                                  ? const EdgeInsets.symmetric(vertical: 16)
                                  : const EdgeInsets.all(16),
                              child: widget,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final (name, _) in Samples.sections(
        tester.element(find.byType(Scaffold)),
      )) {
        await tester.ensureVisible(find.byKey(ValueKey(name)));
        await tester.pumpAndSettle();
        await expectLater(
          find.byKey(ValueKey(name)),
          matchesGoldenFile('goldens/${_file(name)}_$mode.png'),
        );
      }
    });
  }
}

/// `MentionPopover` → `mention_popover`.
String _file(String name) => name
    .replaceAllMapped(RegExp('(?<=[a-z])([A-Z])'), (m) => '_${m[1]}')
    .toLowerCase();
