import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_keyboard_events.dart';
import 'package:pirc_mobile/l10n/app_i18n.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppI18n.instance.setLanguage('en'));
  for (final language in ['en', 'zh-TW']) {
    test('DOM key metadata stays standard in $language', () {
      AppI18n.instance.setLanguage(language);
      for (final (physical, logical, key, code, legacy) in [
        (
          PhysicalKeyboardKey.enter,
          LogicalKeyboardKey.enter,
          'Enter',
          'Enter',
          13,
        ),
        (
          PhysicalKeyboardKey.numpadEnter,
          LogicalKeyboardKey.numpadEnter,
          'Enter',
          'NumpadEnter',
          13,
        ),
        (PhysicalKeyboardKey.tab, LogicalKeyboardKey.tab, 'Tab', 'Tab', 9),
        (
          PhysicalKeyboardKey.escape,
          LogicalKeyboardKey.escape,
          'Escape',
          'Escape',
          27,
        ),
        (
          PhysicalKeyboardKey.backspace,
          LogicalKeyboardKey.backspace,
          'Backspace',
          'Backspace',
          8,
        ),
        (
          PhysicalKeyboardKey.controlLeft,
          LogicalKeyboardKey.controlLeft,
          'Control',
          'ControlLeft',
          17,
        ),
        (
          PhysicalKeyboardKey.arrowLeft,
          LogicalKeyboardKey.arrowLeft,
          'ArrowLeft',
          'ArrowLeft',
          37,
        ),
      ]) {
        final data = nativeHtmlKeyboardEventData(
          KeyDownEvent(
            physicalKey: physical,
            logicalKey: logical,
            timeStamp: Duration.zero,
          ),
        );
        expect(data['key'], key, reason: '$language $key');
        expect(data['code'], code, reason: '$language $key');
        expect(data['keyCode'], legacy, reason: '$language $key');
        expect(data['which'], legacy, reason: '$language $key');
      }
    });
  }
  test('key-up letters retain browser key casing and physical code', () {
    final data = nativeHtmlKeyboardEventData(
      const KeyUpEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: LogicalKeyboardKey.keyA,
        timeStamp: Duration.zero,
      ),
    );
    expect(data['key'], 'a');
    expect(data['code'], 'KeyA');
    expect(data['keyCode'], 65);
    expect(data['repeat'], false);
  });
  test('numpad Enter and repeated composing keys carry distinct metadata', () {
    final data = nativeHtmlKeyboardEventData(
      const KeyRepeatEvent(
        physicalKey: PhysicalKeyboardKey.numpadEnter,
        logicalKey: LogicalKeyboardKey.numpadEnter,
        timeStamp: Duration.zero,
      ),
      isComposing: true,
    );
    expect(data['key'], 'Enter');
    expect(data['code'], 'NumpadEnter');
    expect(data['location'], 3);
    expect(data['repeat'], true);
    expect(data['isComposing'], true);
    expect(data['keyCode'], 13);
  });
}
