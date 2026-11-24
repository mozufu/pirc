import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_buttons.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_form_submission.dart';
import 'package:pirc_render/src/html_inline_intrinsic_overflow.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

Widget _page(
  String source, {
  required NativeHtmlFilePicker filePicker,
  required ValueChanged<NativeHtmlFormSubmission> onFormSubmit,
  bool markdownStyles = false,
  double textScale = 1,
  TextStyle? documentStyle,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: Scaffold(
        body: SingleChildScrollView(
          child: NativeHtmlDocument(
            nodes: [NativeHtmlRaw(source)],
            style:
                documentStyle ??
                const TextStyle(fontSize: 16, color: Colors.black),
            styles: MarkdownStyleSheet(),
            builders: const {},
            markdownStyles: markdownStyles,
            filePicker: filePicker,
            onFormSubmit: onFormSubmit,
          ),
        ),
      ),
    ),
  ),
);

Finder _fileControl(WidgetTester tester, {String? name}) =>
    find.byWidgetPredicate(
      (widget) =>
          widget is NativeHtmlFileInputWidget &&
          (name == null || widget.control.name == name),
    );

NativeHtmlFileInputWidget _fileWidget(WidgetTester tester, {String? name}) =>
    tester.widget<NativeHtmlFileInputWidget>(_fileControl(tester, name: name));

Finder _submitButton(String label) => find.byWidgetPredicate(
  (widget) => widget is NativeHtmlButtonWidget && widget.button.label == label,
);

NativeHtmlFile _file(String name, List<int> bytes, {String? type}) =>
    NativeHtmlFile(
      name: name,
      mimeType: type ?? 'application/octet-stream',
      bytes: bytes,
    );

void main() {
  testWidgets(
    'raw file control answers first-legend intrinsic sizing from effective font metrics',
    (tester) async {
      const sourceTemplate = '''
<fieldset disabled>
  <legend><input id="upload" type="file" name="upload" required style="font-family:Arial;font-size:__FONT_SIZE__px"></legend>
  <input id="fieldset-disabled" type="file" name="blocked">
</fieldset>
''';
      final submissions = <NativeHtmlFormSubmission>[];
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<Size> pumpAndMeasure(double scale) async {
        final source = sourceTemplate.replaceAll(
          '__FONT_SIZE__',
          (13.3333 * scale).toStringAsFixed(4),
        );
        await tester.pumpWidget(
          _page(
            source,
            filePicker: (_) async => null,
            onFormSubmit: submissions.add,
            // Raw controls receive the CSS-injected 1x/2x size directly; the
            // raw-document renderer already disables a second MediaQuery scale.
            textScale: 1,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);

        final file = _fileWidget(tester, name: 'upload');
        expect(file.control.disabled, isFalse);
        final boxStyle = file.boxStyle;
        expect(boxStyle, isNotNull);
        final style = file.textStyle;
        // Raw-document controls are already inside the app's no-text-scaling
        // boundary; the authored inline CSS above carries the 1x/2x size.
        final fontSize = style.fontSize ?? 13.333333333333334;
        final statusStyle =
            DefaultTextStyle.of(
                  tester.element(_fileControl(tester, name: 'upload')),
                ).style
                .merge(style)
                .copyWith(
                  fontSize: fontSize,
                  height: 1,
                  fontWeight: FontWeight.w400,
                );
        final zero = TextPainter(
          text: TextSpan(text: '0', style: statusStyle),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          maxLines: 1,
        )..layout();
        final buttonStyle = TextStyle(
          inherit: false,
          fontFamily: 'Arial',
          fontSize: fontSize,
          color: Colors.black,
          fontWeight: FontWeight.w400,
        );
        final button = TextPainter(
          text: TextSpan(text: 'Choose File', style: buttonStyle),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          maxLines: 1,
        )..layout();
        final border = boxStyle!.border;
        final padding = boxStyle.padding;
        final expected = Size(
          (zero.width * 34).ceilToDouble() +
              padding.horizontal +
              border.dimensions.horizontal,
          (button.height + 6).ceilToDouble() +
              padding.vertical +
              border.dimensions.vertical,
        );
        final actual = tester.getSize(_fileControl(tester, name: 'upload'));
        expect(actual.width, expected.width);
        expect(actual.height, expected.height);
        final intrinsic = tester.widget<NativeHtmlInlineIntrinsicOverflow>(
          find.byKey(
            ValueKey('native-html-file-intrinsic-${file.control.key}'),
          ),
        );
        final baseline = intrinsic.baselineFromTop;
        expect(baseline, isNotNull);
        expect(baseline!, greaterThan(0));
        expect(intrinsic.intrinsicSize.height - baseline, greaterThan(0));
        return actual;
      }

      final oneX = await pumpAndMeasure(1);
      final twoX = await pumpAndMeasure(2);
      expect(oneX.width, greaterThan(0));
      expect(twoX.width, greaterThan(oneX.width * 1.9));
      expect(twoX.height, greaterThan(oneX.height));
    },
  );

  testWidgets(
    'unstyled Markdown file control stays intrinsic and scales with MediaQuery',
    (tester) async {
      const source = '<input id="upload" type="file" name="upload">';
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      Future<Size> pumpAndMeasure(double scale) async {
        await tester.pumpWidget(
          _page(
            source,
            filePicker: (_) async => null,
            onFormSubmit: (_) {},
            markdownStyles: true,
            textScale: scale,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final finder = _fileControl(tester, name: 'upload');
        final file = _fileWidget(tester, name: 'upload');
        expect(file.boxStyle, isNull);
        final element = tester.element(finder);
        final fontSize = MediaQuery.textScalerOf(
          element,
        ).scale(file.textStyle.fontSize ?? 13.333333333333334);
        final inheritedStyle = DefaultTextStyle.of(
          element,
        ).style.merge(file.textStyle);
        final statusStyle = inheritedStyle.copyWith(
          fontSize: fontSize,
          height: 1,
          fontWeight: FontWeight.w400,
        );
        final zero = TextPainter(
          text: TextSpan(text: '0', style: statusStyle),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          maxLines: 1,
        )..layout();
        final button = TextPainter(
          text: TextSpan(
            text: 'Choose File',
            style: TextStyle(
              inherit: false,
              fontFamily: 'Arial',
              fontSize: fontSize,
              color: Colors.black,
              fontWeight: FontWeight.w400,
            ),
          ),
          textDirection: TextDirection.ltr,
          textScaler: TextScaler.noScaling,
          maxLines: 1,
        )..layout();
        final actual = tester.getSize(finder);
        expect(actual.width, (zero.width * 34).ceilToDouble());
        expect(actual.height, (button.height + 6).ceilToDouble());
        expect(actual.width, lessThan(1400));
        return actual;
      }

      final oneX = await pumpAndMeasure(1);
      final twoX = await pumpAndMeasure(2);
      expect(twoX.width, greaterThan(oneX.width * 1.9));
      expect(twoX.height, greaterThan(oneX.height));
    },
  );

  testWidgets(
    'file controls retain authored pixel and percentage width constraints',
    (tester) async {
      const source = '''
<input id="fixed" type="file" name="fixed" style="font-size:8px;width:120px">
<input id="minmax" type="file" name="minmax" style="font-size:8px;min-width:100px;max-width:150px">
<input id="percent" type="file" name="percent" style="font-size:8px;width:50%">
''';
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _page(source, filePicker: (_) async => null, onFormSubmit: (_) {}),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      expect(tester.getSize(_fileControl(tester, name: 'fixed')).width, 120);
      expect(tester.getSize(_fileControl(tester, name: 'minmax')).width, 150);
      expect(
        tester.getSize(_fileControl(tester, name: 'percent')).width,
        closeTo(195, 1),
      );
    },
  );

  testWidgets('raw file button and status retain the document glyph fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      _page(
        '<input id="upload" type="file" name="upload">',
        filePicker: (_) async => null,
        onFormSubmit: (_) {},
        documentStyle: const TextStyle(
          fontSize: 16,
          color: Colors.black,
          fontFamilyFallback: ['source-cjk-fallback'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final fileFinder = _fileControl(tester, name: 'upload');
    final file = tester.widget<NativeHtmlFileInputWidget>(fileFinder);
    expect(file.textStyle.fontFamilyFallback, ['source-cjk-fallback']);

    final buttonText = tester.widget<Text>(
      find.descendant(of: fileFinder, matching: find.text('Choose File')),
    );
    final statusText = tester.widget<Text>(
      find.descendant(of: fileFinder, matching: find.text('No file chosen')),
    );
    expect(buttonText.style?.fontFamily, 'Arial');
    expect(buttonText.style?.fontFamilyFallback, ['source-cjk-fallback']);
    expect(statusText.style?.fontFamilyFallback, ['source-cjk-fallback']);
  });

  testWidgets(
    'file input in a first fieldset legend is tappable beyond paragraph bounds',
    (tester) async {
      const source = '''
<fieldset style="width:100px">
  <legend><input id="upload" type="file" name="upload" style="width:260px"></legend>
</fieldset>
''';
      var pickerCalls = 0;
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        _page(
          source,
          filePicker: (_) async {
            pickerCalls++;
            return null;
          },
          onFormSubmit: (_) {},
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final fileFinder = _fileControl(tester, name: 'upload');
      final overflowHostFinder = find.ancestor(
        of: fileFinder,
        matching: find.byWidgetPredicate(
          (widget) => widget is NativeHtmlInlineOverflowHost,
        ),
      );
      expect(overflowHostFinder, findsOneWidget);

      final overflowHostRect = tester.getRect(overflowHostFinder);
      final fileRect = tester.getRect(fileFinder);
      expect(fileRect.width, 260);
      expect(overflowHostRect.width, lessThan(fileRect.width));
      final point = Offset(overflowHostRect.right + 6, fileRect.center.dy);
      expect(overflowHostRect.contains(point), isFalse);
      expect(fileRect.contains(point), isTrue);
      expect(point.dx, lessThan(390));

      await tester.tapAt(point);
      await tester.pumpAndSettle();
      expect(pickerCalls, 1);
    },
  );

  test(
    'raw sanitizer keeps submitter overrides; Markdown policy strips them',
    () {
      const source = '''
<form action="/default" method="get" enctype="application/x-www-form-urlencoded" target="formWindow">
  <button type="submit" formaction="/override" formmethod="post" formenctype="text/plain" formtarget="resultWindow">Send</button>
</form>
''';

      final raw = sanitizeNativeHtml(source, markdownPolicy: false);
      final markdown = sanitizeNativeHtml(source, markdownPolicy: true);

      expect(raw, contains('formaction="/override"'));
      expect(raw, contains('formmethod="post"'));
      expect(raw, contains('formenctype="text/plain"'));
      expect(raw, contains('formtarget="resultWindow"'));
      expect(markdown, isNot(contains('formaction')));
      expect(markdown, isNot(contains('formmethod')));
      expect(markdown, isNot(contains('formenctype')));
      expect(markdown, isNot(contains('formtarget')));
    },
  );

  testWidgets('required file blocks submit and focuses the native file input', (
    tester,
  ) async {
    const source = '''
<form action="/required" method="post">
  <label for="upload">Attachment</label>
  <input id="upload" type="file" name="upload" required>
  <button type="submit">Submit</button>
</form>
''';
    final submissions = <NativeHtmlFormSubmission>[];
    await tester.pumpWidget(
      _page(
        source,
        filePicker: (_) async => null,
        onFormSubmit: submissions.add,
      ),
    );
    await tester.pumpAndSettle();

    final file = _fileWidget(tester, name: 'upload');
    expect(file.state.willValidate(file.control.key), isTrue);
    expect(file.state.valueMissing(file.control.key), isTrue);
    await tester.tap(_submitButton('Submit'));
    await tester.pumpAndSettle();

    expect(submissions, isEmpty);
    expect(file.state.focusNodeFor(file.control.key).hasFocus, isTrue);
    expect(find.text('Please select a file.'), findsOneWidget);
  });

  testWidgets(
    'multiple file entries keep order around each submitter in GET and multipart',
    (tester) async {
      const source = '''
<form action="/get" method="get">
  <input type="text" name="beforeGet" value="B">
  <input id="uploads-get" type="file" name="uploadGet" multiple>
  <button type="submit" name="go" value="get">GET</button>
  <input type="text" name="afterGet" value="A">
</form>
<form action="/multipart" method="post" enctype="multipart/form-data">
  <input type="text" name="beforePost" value="B">
  <input id="uploads-post" type="file" name="uploadPost" multiple>
  <button type="submit" name="go" value="post">POST</button>
  <input type="text" name="afterPost" value="A">
</form>
''';
      final submissions = <NativeHtmlFormSubmission>[];
      var pickerCalls = 0;
      final files = [
        _file('one résumé-台北.txt', [0x4c, 0x00, 0xff], type: 'text/plain'),
        _file('two + space.bin', [0x00, 0x41, 0xff, 0x0d, 0x0a, 0x42, 0x80]),
      ];
      await tester.pumpWidget(
        _page(
          source,
          filePicker: (_) async {
            pickerCalls++;
            return files;
          },
          onFormSubmit: submissions.add,
        ),
      );
      await tester.pumpAndSettle();

      final getFile = _fileWidget(tester, name: 'uploadGet');
      await tester.tap(_fileControl(tester, name: 'uploadGet'));
      await tester.pumpAndSettle();
      expect(pickerCalls, 1);
      expect(getFile.state.filesFor(getFile.control.key).map((f) => f.name), [
        'one résumé-台北.txt',
        'two + space.bin',
      ]);

      await tester.tap(_submitButton('GET'));
      await tester.pumpAndSettle();
      expect(submissions, hasLength(1));
      final getSubmission = submissions.single;
      expect(getSubmission.action, '/get');
      expect(getSubmission.method, 'get');
      expect(getSubmission.entries.map((entry) => entry.name).toList(), [
        'beforeGet',
        'uploadGet',
        'uploadGet',
        'go',
        'afterGet',
      ]);
      expect(
        getSubmission.entries.lastWhere((entry) => entry.name == 'go').value,
        'get',
      );
      expect(
        getSubmission.entries
            .where((entry) => entry.isFile)
            .map((entry) => entry.file!.name),
        ['one résumé-台北.txt', 'two + space.bin'],
      );
      final getRequest = getSubmission.buildRequest();
      expect(getRequest.method, 'GET');
      expect(
        getRequest.query,
        'beforeGet=B&uploadGet=one+r%C3%A9sum%C3%A9-%E5%8F%B0%E5%8C%97.txt&uploadGet=two+%2B+space.bin&go=get&afterGet=A',
      );
      expect(getRequest.bodyBytes, isNull);

      final postFile = _fileWidget(tester, name: 'uploadPost');
      await tester.tap(_fileControl(tester, name: 'uploadPost'));
      await tester.pumpAndSettle();
      expect(pickerCalls, 2);
      expect(postFile.state.filesFor(postFile.control.key).map((f) => f.name), [
        'one résumé-台北.txt',
        'two + space.bin',
      ]);

      await tester.tap(_submitButton('POST'));
      await tester.pumpAndSettle();
      expect(submissions, hasLength(2));
      final postSubmission = submissions.last;
      expect(postSubmission.action, '/multipart');
      expect(postSubmission.method, 'post');
      expect(postSubmission.entries.map((entry) => entry.name).toList(), [
        'beforePost',
        'uploadPost',
        'uploadPost',
        'go',
        'afterPost',
      ]);
      expect(
        postSubmission.entries.lastWhere((entry) => entry.name == 'go').value,
        'post',
      );
      final postRequest = postSubmission.buildRequest();
      expect(postRequest.method, 'POST');
      expect(
        postRequest.contentType,
        startsWith('multipart/form-data; boundary='),
      );
      expect(postRequest.body, isNull);
      final bytes = postRequest.bodyBytes!;
      expect(bytes, isA<Uint8List>());
      expect(bytes, contains(0xff));
      final wire = String.fromCharCodes(bytes);
      expect(
        wire.indexOf('name="beforePost"'),
        lessThan(wire.indexOf('name="uploadPost"')),
      );
      expect(
        wire.indexOf('filename="one résumé-台北.txt"'),
        lessThan(wire.indexOf('filename="two + space.bin"')),
      );
      expect(
        wire.indexOf('name="go"'),
        lessThan(wire.indexOf('name="afterPost"')),
      );
    },
  );

  testWidgets(
    'raw submitter overrides GET form with text/plain POST and preserves tree order',
    (tester) async {
      const source = '''
<form action="/default" method="get" enctype="application/x-www-form-urlencoded" target="formWindow">
  <input type="text" name="before" value="B">
  <input id="upload" type="file" name="upload" required>
  <button type="submit" id="override" name="commit" value="send" formaction="/override" formmethod="post" formenctype="text/plain" formtarget="resultWindow">Override</button>
  <input type="text" name="after" value="A">
</form>
''';
      final submissions = <NativeHtmlFormSubmission>[];
      await tester.pumpWidget(
        _page(
          source,
          filePicker: (_) async => [
            _file('résumé.txt', [0x41, 0x00, 0xff], type: 'text/plain'),
          ],
          onFormSubmit: submissions.add,
        ),
      );
      await tester.pumpAndSettle();

      final file = _fileWidget(tester, name: 'upload');
      expect(file.state.willValidate(file.control.key), isTrue);
      await tester.tap(_fileControl(tester, name: 'upload'));
      await tester.pumpAndSettle();
      expect(file.state.filesFor(file.control.key).single.name, 'résumé.txt');

      await tester.tap(_submitButton('Override'));
      await tester.pumpAndSettle();

      expect(submissions, hasLength(1));
      final submission = submissions.single;
      expect(submission.action, '/override');
      expect(submission.method, 'post');
      expect(submission.enctype, 'text/plain');
      expect(submission.target, 'resultWindow');
      expect(submission.targetSpecified, isTrue);
      expect(submission.submitterId, 'override');
      expect(submission.entries.map((entry) => entry.name), [
        'before',
        'upload',
        'commit',
        'after',
      ]);
      expect(submission.entries[1].file!.name, 'résumé.txt');
      expect(submission.entries[2].value, 'send');

      final request = submission.buildRequest();
      expect(request.url, '/override');
      expect(request.method, 'POST');
      expect(request.target, 'resultWindow');
      expect(request.targetSpecified, isTrue);
      expect(request.contentType, 'text/plain');
      expect(
        request.body,
        'before=B\r\nupload=résumé.txt\r\ncommit=send\r\nafter=A\r\n',
      );
      expect(request.bodyBytes, isNull);
    },
  );

  testWidgets('cancel preserves selected files and reset clears them', (
    tester,
  ) async {
    const source = '''
<form action="/file" method="post" enctype="multipart/form-data">
  <input id="upload" type="file" name="upload" multiple>
  <button type="button">Pick</button>
  <button type="reset">Reset</button>
  <button type="submit">Submit</button>
</form>
''';
    var pickerCalls = 0;
    final submissions = <NativeHtmlFormSubmission>[];
    await tester.pumpWidget(
      _page(
        source,
        filePicker: (_) async {
          pickerCalls++;
          return pickerCalls == 1
              ? [
                  _file('saved.txt', [1, 2, 3]),
                ]
              : null;
        },
        onFormSubmit: submissions.add,
      ),
    );
    await tester.pumpAndSettle();

    var file = _fileWidget(tester, name: 'upload');
    await tester.tap(_fileControl(tester, name: 'upload'));
    await tester.pumpAndSettle();
    await tester.tap(_fileControl(tester, name: 'upload'));
    await tester.pumpAndSettle();
    file = _fileWidget(tester, name: 'upload');
    expect(file.state.filesFor(file.control.key).single.name, 'saved.txt');

    await tester.tap(_submitButton('Submit'));
    await tester.pumpAndSettle();
    expect(submissions, hasLength(1));
    expect(submissions.single.entries.single.file!.name, 'saved.txt');

    await tester.tap(_submitButton('Reset'));
    await tester.pumpAndSettle();
    file = _fileWidget(tester, name: 'upload');
    expect(file.state.filesFor(file.control.key), isEmpty);
  });

  testWidgets(
    'disabled required file is barred; readonly file remains selectable and submits',
    (tester) async {
      const source = '''
<form action="/file" method="post">
  <input id="disabled" type="file" name="disabledFile" required disabled>
  <fieldset disabled>
    <input id="fieldset" type="file" name="fieldsetFile" required>
  </fieldset>
  <input id="readonly" type="file" name="readonlyFile" required readonly>
  <button type="submit">Submit</button>
</form>
''';
      var pickerCalls = 0;
      final submissions = <NativeHtmlFormSubmission>[];
      await tester.pumpWidget(
        _page(
          source,
          filePicker: (_) async {
            pickerCalls++;
            return [
              _file('readonly.txt', [9]),
            ];
          },
          onFormSubmit: submissions.add,
        ),
      );
      await tester.pumpAndSettle();

      final disabled = _fileWidget(tester, name: 'disabledFile');
      final fieldsetDisabled = _fileWidget(tester, name: 'fieldsetFile');
      final readonly = _fileWidget(tester, name: 'readonlyFile');
      expect(disabled.state.willValidate(disabled.control.key), isFalse);
      expect(disabled.state.valueMissing(disabled.control.key), isTrue);
      expect(
        fieldsetDisabled.state.willValidate(fieldsetDisabled.control.key),
        isFalse,
      );
      expect(
        fieldsetDisabled.state.valueMissing(fieldsetDisabled.control.key),
        isTrue,
      );
      expect(readonly.control.disabled, isFalse);
      expect(readonly.state.willValidate(readonly.control.key), isTrue);

      await tester.tap(_fileControl(tester, name: 'disabledFile'));
      await tester.pumpAndSettle();
      await tester.tap(_fileControl(tester, name: 'fieldsetFile'));
      await tester.pumpAndSettle();
      expect(pickerCalls, 0);
      await tester.tap(_fileControl(tester, name: 'readonlyFile'));
      await tester.pumpAndSettle();
      expect(pickerCalls, 1);
      expect(
        readonly.state.filesFor(readonly.control.key).single.name,
        'readonly.txt',
      );

      await tester.tap(_submitButton('Submit'));
      await tester.pumpAndSettle();
      expect(submissions, hasLength(1));
      expect(submissions.single.entries.map((entry) => entry.name).toList(), [
        'readonlyFile',
      ]);
      expect(submissions.single.entries.single.file!.name, 'readonly.txt');
    },
  );
}
