import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/pot_draft.dart';
import 'package:pirc_app/src/platform/files.dart';
import 'package:pirc_app/src/work/composer/attachment_input.dart';
import 'package:pirc_app/src/work/composer/attachments.dart';

import 'support/harness.dart';
import 'support/session_fixture.dart';

final _png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47]);

PickedFile _image(String name) =>
    PickedFile(name: name, mimeType: 'image/png', bytes: _png);

String _block(Map<String, Object?> data) =>
    '```pirc-artifact\n${jsonEncode(data)}\n```';

void main() {
  group('the channel', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late ChannelFilesPlatform files;
    final calls = <MethodCall>[];
    Object? Function(MethodCall call) answer = (_) => null;

    setUp(() {
      calls.clear();
      answer = (_) => null;
      files = ChannelFilesPlatform();
      messenger.setMockMethodCallHandler(ChannelFilesPlatform.channel, (
        call,
      ) async {
        calls.add(call);
        return answer(call);
      });
    });
    tearDown(() {
      files.dispose();
      messenger.setMockMethodCallHandler(ChannelFilesPlatform.channel, null);
    });

    test('pick maps read and refused files', () async {
      expect(ChannelFilesPlatform.channel.name, 'org.mozufu.pirc/files');
      answer = (_) => [
        {'name': 'a.png', 'mimeType': 'image/png', 'bytes': _png},
        {'name': 'big.bin', 'mimeType': 'x/y', 'error': 'TOO_LARGE'},
        {'name': 'gone.txt', 'mimeType': 'text/plain', 'error': 'READ'},
        {'name': 'f17.txt', 'mimeType': 'text/plain', 'error': 'TOO_MANY'},
      ];
      final pick = await files.pick(multiple: false, mimeTypes: ['image/png']);
      expect(calls.single.method, 'pick');
      expect(calls.single.arguments, {
        'multiple': false,
        'mimeTypes': ['image/png'],
        'maxBytes': FilesPlatform.maxFileBytes,
      });
      expect(pick.files.single.name, 'a.png');
      expect(pick.files.single.bytes, _png);
      expect(
        [for (final r in pick.refused) (r.name, r.reason)],
        [
          ('big.bin', RefusedFile.tooLarge),
          ('gone.txt', RefusedFile.unreadable),
          ('f17.txt', RefusedFile.tooMany),
        ],
      );
    });

    test('a cancelled pick is empty; a refused one throws its code', () async {
      expect((await files.pick()).isEmpty, isTrue);
      answer = (_) => throw PlatformException(code: 'BUSY');
      await expectLater(
        files.pick(),
        throwsA(
          isA<FilesFailure>().having((f) => f.code, 'code', FilesError.busy),
        ),
      );
      answer = (_) => throw PlatformException(code: 'UNAVAILABLE');
      await expectLater(
        files.pick(),
        throwsA(
          isA<FilesFailure>().having(
            (f) => f.code,
            'code',
            FilesError.unavailable,
          ),
        ),
      );
    });

    test('save sends the bytes and gives the saved name or null', () async {
      answer = (_) => 'report (1).pdf';
      final name = await files.save(
        _png,
        name: 'report.pdf',
        mimeType: 'application/pdf',
      );
      expect(name, 'report (1).pdf');
      expect(calls.single.method, 'save');
      expect(calls.single.arguments, {
        'bytes': _png,
        'name': 'report.pdf',
        'mimeType': 'application/pdf',
      });
      answer = (_) => null;
      expect(await files.save(_png, name: 'a', mimeType: 'text/plain'), isNull);
      expect(
        () => files.save(
          Uint8List(FilesPlatform.maxSaveBytes + 1),
          name: 'a',
          mimeType: 'text/plain',
        ),
        throwsA(isA<FilesFailure>()),
      );
    });

    test('share text, and long text as a file', () async {
      await files.shareText('hello', subject: 'Report');
      expect(calls.single.method, 'shareText');
      expect(calls.single.arguments, {'text': 'hello', 'subject': 'Report'});

      calls.clear();
      answer = (call) => call.method == 'sharePart' ? 4 : null;
      await files.shareText(
        'x' * (FilesPlatform.maxShareText + 1),
        subject: 'Report',
      );
      expect(calls.map((c) => c.method), ['sharePart', 'shareFile']);
      expect(calls.last.arguments, {
        'share': 4,
        'name': 'Report.txt',
        'mimeType': 'text/plain',
      });
    });

    test('a shared file goes in parts', () async {
      answer = (call) => call.method == 'sharePart' ? 9 : null;
      final bytes = Uint8List(FilesPlatform.partBytes + 3);
      await files.shareFile(bytes, name: 'a.webm', mimeType: 'video/webm');
      expect(calls.map((c) => c.method), [
        'sharePart',
        'sharePart',
        'shareFile',
      ]);
      expect((calls[0].arguments as Map).containsKey('share'), isFalse);
      expect(
        ((calls[0].arguments as Map)['bytes'] as Uint8List).length,
        FilesPlatform.partBytes,
      );
      expect((calls[1].arguments as Map)['share'], 9);
      expect(((calls[1].arguments as Map)['bytes'] as Uint8List).length, 3);
      expect(calls[2].arguments, {
        'share': 9,
        'name': 'a.webm',
        'mimeType': 'video/webm',
      });
    });

    test('a failed part discards the upload', () async {
      var parts = 0;
      answer = (call) {
        if (call.method != 'sharePart') return null;
        if (++parts == 2) throw PlatformException(code: 'FILES');
        return 5;
      };
      await expectLater(
        files.shareFile(
          Uint8List(FilesPlatform.partBytes + 1),
          name: 'a.webm',
          mimeType: 'video/webm',
        ),
        throwsA(isA<FilesFailure>()),
      );
      expect(calls.map((c) => c.method), [
        'sharePart',
        'sharePart',
        'shareDiscard',
      ]);
      expect(calls.last.arguments, {'share': 5});
    });

    test('clipboard images', () async {
      answer = (call) => switch (call.method) {
        'clipboardHasImages' => true,
        'clipboardImages' => [
          {'name': 'cat.png', 'mimeType': 'image/png', 'bytes': _png},
        ],
        _ => null,
      };
      expect(await files.clipboardHasImages(), isTrue);
      expect((await files.clipboardImages()).files.single.name, 'cat.png');
    });

    test('a drop target and a drop from Kotlin', () async {
      await files.setDropTarget(3, const Rect.fromLTRB(10, 20, 110, 70), 2.5);
      expect(calls.single.arguments, {
        'token': 3,
        'left': 10.0,
        'top': 20.0,
        'right': 110.0,
        'bottom': 70.0,
        'devicePixelRatio': 2.5,
      });
      final drop = files.drops.first;
      await messenger.handlePlatformMessage(
        ChannelFilesPlatform.channel.name,
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('dropped', {
            'token': 3,
            'files': [
              {'name': 'drop.png', 'mimeType': 'image/png', 'bytes': _png},
            ],
          }),
        ),
        (_) {},
      );
      final dropped = await drop;
      expect(dropped.token, 3);
      expect(dropped.pick.files.single.name, 'drop.png');
      await files.clearDropTarget(3);
      expect(calls.last.method, 'clearDropTarget');
    });
  });

  group('the avatar picture', () {
    test('picks one image; cancelled is null, refused throws', () async {
      final files = FakeFilesPlatform(
        picks: [
          FilePick.empty,
          const FilePick(refused: [RefusedFile('big.png', 'TOO_LARGE')]),
          const FilesFailure(FilesError.busy),
        ],
      );
      final container = ProviderContainer(
        overrides: [filesPlatformProvider.overrideWithValue(files)],
      );
      addTearDown(container.dispose);
      final pick = container.read(avatarPicturePickerProvider);
      expect(await pick(), isNull);
      final (multiple, mimeTypes, maxBytes) = files.pickCalls.single;
      expect(multiple, isFalse);
      expect(mimeTypes, ['image/png', 'image/jpeg', 'image/webp']);
      // The source may be larger than an upload: it is cropped first.
      expect(maxBytes, FilesPlatform.maxPickBytes);
      await expectLater(
        pick(),
        throwsA(isA<FilesFailure>().having((f) => f.code, 'code', 'TOO_LARGE')),
      );
      await expectLater(pick(), throwsA(isA<FilesFailure>()));
    });
  });

  group('the composer', () {
    Future<FakeFilesPlatform> open(
      WidgetTester tester, {
      List<Object>? picks,
      FilePick clipboard = FilePick.empty,
      String location = '/work?open=s2',
    }) async {
      final files = FakeFilesPlatform(picks: picks, clipboard: clipboard);
      final s = FixtureSession('joined-mid-stream.json');
      await pumpApp(
        tester,
        gateway: s.install(),
        location: location,
        files: files,
      );
      return files;
    }

    Finder chip(String name) =>
        find.ancestor(of: find.text(name), matching: find.byType(InputChip));

    appTest('attach uses the system picker', (tester) async {
      final files = await open(
        tester,
        picks: [
          FilePick(files: [_image('a.png'), _image('b.png')]),
        ],
      );
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      final (multiple, mimeTypes, maxBytes) = files.pickCalls.single;
      expect(multiple, isTrue);
      expect(mimeTypes, isEmpty);
      expect(maxBytes, FilesPlatform.maxFileBytes);
      expect(chip('a.png'), findsOneWidget);
      expect(chip('b.png'), findsOneWidget);
    });

    appTest('a cancelled pick adds nothing', (tester) async {
      await open(tester, picks: [FilePick.empty]);
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(find.byType(InputChip), findsNothing);
      expect(find.byType(SnackBar), findsNothing);
    });

    appTest('refused files are named and the rest are added', (tester) async {
      await open(
        tester,
        picks: [
          FilePick(
            files: [_image('ok.png')],
            refused: const [RefusedFile('big.mov', 'TOO_LARGE')],
          ),
        ],
      );
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(chip('ok.png'), findsOneWidget);
      expect(find.text('Not added, too large: big.mov.'), findsOneWidget);
    });

    appTest('a tap while a picker is open is ignored quietly', (tester) async {
      await open(tester, picks: [const FilesFailure(FilesError.busy)]);
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsNothing);
    });

    appTest('files past the count or total are named by reason', (
      tester,
    ) async {
      await open(
        tester,
        picks: [
          FilePick(
            files: [_image('ok.png')],
            refused: const [
              RefusedFile('17.png', RefusedFile.tooMany),
              RefusedFile('bad.png', RefusedFile.unreadable),
            ],
          ),
        ],
      );
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(chip('ok.png'), findsOneWidget);
      expect(
        find.text(
          'Not added, more than 16 files or 64 MiB at once: 17.png.\n'
          'Not added, could not be read: bad.png.',
        ),
        findsOneWidget,
      );
    });

    appTest('a picker that cannot open says so', (tester) async {
      await open(tester, picks: [const FilesFailure(FilesError.unavailable)]);
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(find.text('The file picker could not open.'), findsOneWidget);
      expect(find.byType(InputChip), findsNothing);
    });

    EditableTextState field(WidgetTester tester) =>
        tester.state<EditableTextState>(
          find.descendant(
            of: find.byKey(const Key('composer-field')),
            matching: find.byType(EditableText),
          ),
        );

    /// The system clipboard's text part, as Flutter reads it.
    void clipboardText(WidgetTester tester, String? text) =>
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => switch (call.method) {
            'Clipboard.getData' => text == null ? null : {'text': text},
            'Clipboard.hasStrings' => {'value': text != null},
            _ => null,
          },
        );

    appTest('Paste takes the images and the text of the clipboard', (
      tester,
    ) async {
      final files = await open(
        tester,
        clipboard: FilePick(files: [_image('cat.png')]),
      );
      clipboardText(tester, 'see');
      await tester.tap(find.byKey(const Key('composer-field')));
      await tester.pumpAndSettle();
      field(tester).showToolbar();
      await tester.pumpAndSettle();
      // One Paste, the field's own, not a second item.
      expect(find.text('Paste'), findsOneWidget);
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(chip('cat.png'), findsOneWidget);
      expect(field(tester).textEditingValue.text, 'see');
      expect(files.clipboardReads, 1);
    });

    appTest('Paste is offered for an image alone', (tester) async {
      await open(tester, clipboard: FilePick(files: [_image('only.png')]));
      clipboardText(tester, null);
      await tester.tap(find.byKey(const Key('composer-field')));
      await tester.pumpAndSettle();
      field(tester).showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(chip('only.png'), findsOneWidget);
      expect(find.byType(AdaptiveTextSelectionToolbar), findsNothing);
    });

    appTest('Ctrl+V pastes the images too', (tester) async {
      await open(tester, clipboard: FilePick(files: [_image('key.png')]));
      clipboardText(tester, 'typed');
      await tester.tap(find.byKey(const Key('composer-field')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();
      expect(chip('key.png'), findsOneWidget);
      expect(field(tester).textEditingValue.text, 'typed');
    });

    appTest('a text clipboard reads no images', (tester) async {
      final files = await open(tester);
      clipboardText(tester, 'just text');
      await tester.tap(find.byKey(const Key('composer-field')));
      await tester.pumpAndSettle();
      field(tester).showToolbar();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();
      expect(field(tester).textEditingValue.text, 'just text');
      expect(files.clipboardReads, 0);
      expect(find.byType(InputChip), findsNothing);
    });

    appTest('an image the keyboard inserts is attached', (tester) async {
      await open(tester);
      tester
          .state<EditableTextState>(
            find.descendant(
              of: find.byKey(const Key('composer-field')),
              matching: find.byType(EditableText),
            ),
          )
          .insertContent(
            KeyboardInsertedContent(
              mimeType: 'image/png',
              uri:
                  'content://com.google.android.inputmethod.latin/c/st\u202Eick.png',
              data: _png,
            ),
          );
      await tester.pumpAndSettle();
      expect(chip('stick.png'), findsOneWidget);
    });

    appTest('the composer takes dropped images while it is shown', (
      tester,
    ) async {
      final files = await open(tester);
      expect(files.dropTargets, hasLength(1));
      final bounds = files.dropTargets.values.single;
      expect(bounds.isEmpty, isFalse);
      files.drop(
        FilePick(
          files: [_image('drop.png')],
          refused: const [RefusedFile('huge.png', 'TOO_LARGE')],
        ),
      );
      await tester.pumpAndSettle();
      expect(chip('drop.png'), findsOneWidget);
      expect(find.text('Not added, too large: huge.png.'), findsOneWidget);

      // Split screen: the window loses focus while the user drags from the
      // other app, and the target stays. In the background it goes.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(files.dropTargets, hasLength(1));
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pump();
      expect(files.dropTargets, isEmpty);
      for (final state in [
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(files.dropTargets, hasLength(1));

      // Leaving the conversation takes the target back.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(files.dropTargets, isEmpty);
    });

    appTest('a new conversation attaches through the system picker', (
      tester,
    ) async {
      final files = await open(
        tester,
        location: '/work?open=new',
        picks: [
          FilePick(files: [_image('n.png')]),
        ],
      );
      expect(files.dropTargets, hasLength(1));
      await tester.tap(find.byTooltip('Attach files'));
      await tester.pumpAndSettle();
      expect(chip('n.png'), findsOneWidget);
    });
  });

  appTest('a result is shared through the share sheet', (tester) async {
    final s = FixtureSession('joined-mid-stream.json');
    (s.snapshot['history']! as List).add({
      'role': 'assistant',
      'content': [
        {
          'type': 'text',
          'text':
              'Here.\n\n${_block({'id': 'r', 'version': 1, 'title': 'API report', 'type': 'markdown', 'summary': 'S', 'status': 'complete', 'content': 'Body'})}',
        },
      ],
      'stopReason': 'stop',
      'timestamp': 2000,
    });
    final files = FakeFilesPlatform();
    await pumpApp(
      tester,
      gateway: s.install(),
      height: 1200,
      location: '/work?open=s2',
      files: files,
    );
    final open = find.text('Open');
    await tester.ensureVisible(open);
    await tester.pumpAndSettle();
    await tester.tap(open);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Share').first);
    await tester.pumpAndSettle();
    expect(files.sharedTexts.single, ('Body', 'API report'));
  });

  test('keyboard images are limited and named cleanly', () {
    KeyboardInsertedContent content(String mimeType, [Uint8List? data]) =>
        KeyboardInsertedContent(
          mimeType: mimeType,
          uri: 'content://keyboard/a\u200B/../x\u0007.gif',
          data: data,
        );
    final ok = keyboardImage(content('image/gif', _png));
    expect(ok.files.single.name, 'x.gif');
    expect(ok.files.single.mimeType, 'image/gif');
    expect(
      keyboardImage(
        content('image/gif', Uint8List(FilesPlatform.maxFileBytes + 1)),
      ).refused.single.reason,
      RefusedFile.tooLarge,
    );
    expect(
      keyboardImage(content('image/gif')).refused.single.reason,
      RefusedFile.unreadable,
    );
    expect(keyboardImage(content('text/plain', _png)).isEmpty, isTrue);
    expect(cleanFileName('../\u202E'), 'image');
    expect(cleanFileName(r'a\b.png'), 'b.png');
    // As Kotlin: every Cf character (U+061C, tag characters) and 200 units.
    expect(cleanFileName('a\u061Cb\u{E0041}.png'), 'ab.png');
    expect(cleanFileName('a' * 300).length, 200);
    expect(cleanFileName('${'a' * 199}\u{1F600}').length, 199);
  });

  test('a pick becomes pending attachments with new IDs', () {
    final pick = AttachmentPick.from(
      FilePick(
        files: [_image('a.png')],
        refused: const [RefusedFile('b', 'READ')],
      ),
    );
    expect(pick.files.single.name, 'a.png');
    expect(pick.files.single.id, isNotEmpty);
    expect([for (final r in pick.refused) r.name], ['b']);
  });
}
