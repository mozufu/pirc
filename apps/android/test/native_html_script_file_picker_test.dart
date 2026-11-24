import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_file.dart';
import 'package:pirc_render/src/html_syntax.dart';
import 'package:pirc_render/src/native_html.dart';

import 'live_test.dart' show theme;

Map<String, dynamic> _action({
  int id = 1,
  int sequence = 1,
  required String controlId,
  String resetVersion = '0',
  String accept = '.txt,text/plain',
  bool multiple = false,
}) => {
  'id': id,
  'sequence': sequence,
  'kind': 'file',
  'controlId': controlId,
  'accept': accept,
  'multiple': multiple,
  'resetVersion': resetVersion,
  'actionOrder': id,
};

NativeHtmlFile _file(
  String name,
  List<int> bytes, {
  String type = 'text/plain',
  int modified = 1,
}) => NativeHtmlFile(
  name: name,
  mimeType: type,
  bytes: bytes,
  lastModified: modified,
);

Widget _page({
  required String source,
  required Object scriptDocument,
  required List<Map<String, dynamic>> actions,
  required List<Map<String, dynamic>> Function(List<int>) take,
  required NativeHtmlScriptFileSelections selections,
  required NativeHtmlFilePicker picker,
  required Future<void> Function(
    int, {
    List<Map<String, dynamic>>? files,
    bool cancelled,
    String? error,
  })
  onResult,
  required Future<bool> Function(
    String,
    String,
    List<Map<String, dynamic>>, {
    String? submitter,
  })
  onEvent,
}) => MaterialApp(
  theme: theme.build(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      child: NativeHtmlDocument(
        nodes: [NativeHtmlRaw(source)],
        style: const TextStyle(fontSize: 16, color: Colors.black),
        styles: MarkdownStyleSheet(),
        builders: const {},
        markdownStyles: false,
        scriptDocument: scriptDocument,
        scriptFilePickerActions: actions,
        takeScriptFilePickerActions: take,
        onScriptFilePickerResult: onResult,
        scriptFileSelections: selections,
        filePicker: picker,
        onScriptEvent: onEvent,
      ),
    ),
  ),
);

Finder _fileControl(String scriptId) => find.byWidgetPredicate(
  (widget) =>
      widget is NativeHtmlFileInputWidget &&
      widget.control.scriptId == scriptId,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('hidden script file input still reaches the native picker', (
    tester,
  ) async {
    const controlId = 'pirc-301';
    final owner = Object();
    final selections = NativeHtmlScriptFileSelections();
    final pickedFile = _file('hidden.txt', [0, 128, 255]);
    final requests = <NativeHtmlFilePickerRequest>[];
    final completions =
        <({int id, List<Map<String, dynamic>>? files, bool cancelled})>[];
    final events = <String>[];
    var supplied = false;
    var pickerCalls = 0;
    final action = _action(
      controlId: controlId,
      sequence: 11,
      resetVersion: '3',
      accept: '.txt, text/plain',
    );

    await tester.pumpWidget(
      _page(
        source:
            '<input type="file" style="display:none" data-pirc-script-id="$controlId" data-pirc-file-reset-version="3">',
        scriptDocument: owner,
        actions: [action],
        take: (painted) {
          if (supplied || !painted.contains(11)) return const [];
          supplied = true;
          return [action];
        },
        selections: selections,
        picker: (request) async {
          pickerCalls++;
          requests.add(request);
          return [pickedFile];
        },
        onResult: (id, {files, cancelled = false, error}) async {
          completions.add((id: id, files: files, cancelled: cancelled));
        },
        onEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(pickerCalls, 1);
    expect(requests.single.accept, ['.txt', 'text/plain']);
    expect(requests.single.multiple, isFalse);
    expect(completions, hasLength(1));
    expect(completions.single.id, 1);
    expect(completions.single.cancelled, isFalse);
    expect(completions.single.files!.single['bytesBase64'], 'AID/');
    expect(selections.get(controlId, '3')!.single.bytes, [0, 128, 255]);
    expect(events, isEmpty);
  });

  testWidgets('detached script input selection is retained when it reconnects', (
    tester,
  ) async {
    const controlId = 'pirc-302';
    final owner = Object();
    final selections = NativeHtmlScriptFileSelections();
    final chosen = _file('detached.txt', [7, 8, 9], modified: 42);
    final completions = <List<Map<String, dynamic>>?>[];
    final events = <String>[];
    var supplied = false;
    var pickerCalls = 0;
    final action = _action(
      id: 2,
      sequence: 22,
      controlId: controlId,
      resetVersion: '5',
    );
    List<Map<String, dynamic>> take(List<int> painted) {
      if (supplied || !painted.contains(22)) return const [];
      supplied = true;
      return [action];
    }

    Widget build(String source, List<Map<String, dynamic>> actions) => _page(
      source: source,
      scriptDocument: owner,
      actions: actions,
      take: take,
      selections: selections,
      picker: (_) async {
        pickerCalls++;
        return [chosen];
      },
      onResult: (id, {files, cancelled = false, error}) async {
        completions.add(files);
      },
      onEvent: (id, type, controls, {submitter}) async {
        events.add('$id:$type');
        return false;
      },
    );

    await tester.pumpWidget(build('<button>Upload</button>', [action]));
    await tester.pumpAndSettle();
    expect(pickerCalls, 1);
    expect(completions, hasLength(1));
    expect(completions.single!.single['bytesBase64'], 'BwgJ');
    expect(selections.get(controlId, '5')!.single.lastModified, 42);
    expect(events, isEmpty);

    await tester.pumpWidget(
      build(
        '<input type="file" data-pirc-script-id="$controlId" data-pirc-file-reset-version="5">',
        const [],
      ),
    );
    await tester.pumpAndSettle();
    final widget = tester.widget<NativeHtmlFileInputWidget>(
      _fileControl(controlId),
    );
    expect(widget.state.filesFor(widget.control.key).single.lastModified, 42);
    expect(widget.state.filesFor(widget.control.key).single.bytes, [7, 8, 9]);
    expect(pickerCalls, 1);
    expect(events, isEmpty);
  });

  testWidgets('script file result preserves the exact 2 MiB budget', (
    tester,
  ) async {
    const controlId = 'pirc-303';
    final owner = Object();
    final selections = NativeHtmlScriptFileSelections();
    final exactBytes = Uint8List(2 * 1024 * 1024);
    for (var i = 0; i < exactBytes.length; i += 1) {
      exactBytes[i] = i % 251;
    }
    final selected = [
      _file('exact.bin', exactBytes, type: 'application/octet-stream'),
      _file('over-budget.bin', [77], type: 'application/octet-stream'),
    ];
    final completions = <List<Map<String, dynamic>>?>[];
    final events = <String>[];
    var supplied = false;
    var pickerCalls = 0;
    final action = _action(
      id: 3,
      sequence: 33,
      controlId: controlId,
      multiple: true,
    );

    await tester.pumpWidget(
      _page(
        source: '<input type="file" multiple data-pirc-script-id="$controlId">',
        scriptDocument: owner,
        actions: [action],
        take: (painted) {
          if (supplied || !painted.contains(33)) return const [];
          supplied = true;
          return [action];
        },
        selections: selections,
        picker: (request) async {
          pickerCalls++;
          expect(request.multiple, isTrue);
          return selected;
        },
        onResult: (id, {files, cancelled = false, error}) async {
          completions.add(files);
        },
        onEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(pickerCalls, 1);
    final wire = completions.single!;
    expect(wire, hasLength(2));
    expect(wire[0]['size'], 2 * 1024 * 1024);
    expect(wire[0]['bytesBase64'], base64Encode(exactBytes));
    expect(wire[0].containsKey('contentError'), isFalse);
    expect(wire[1]['size'], 1);
    expect(wire[1].containsKey('bytesBase64'), isFalse);
    expect(wire[1]['contentError'], contains('2 MiB'));
    expect(events, isEmpty);
  });

  testWidgets('cancel keeps the existing script file selection', (
    tester,
  ) async {
    const controlId = 'pirc-304';
    final owner = Object();
    final selections = NativeHtmlScriptFileSelections();
    final existing = _file('existing.txt', [1, 2, 3], modified: 91);
    selections.store(controlId, '7', [existing]);
    final completions =
        <({bool cancelled, List<Map<String, dynamic>>? files})>[];
    final events = <String>[];
    var supplied = false;
    var pickerCalls = 0;
    final action = _action(
      id: 4,
      sequence: 44,
      controlId: controlId,
      resetVersion: '7',
    );

    await tester.pumpWidget(
      _page(
        source:
            '<input type="file" data-pirc-script-id="$controlId" data-pirc-file-reset-version="7">',
        scriptDocument: owner,
        actions: [action],
        take: (painted) {
          if (supplied || !painted.contains(44)) return const [];
          supplied = true;
          return [action];
        },
        selections: selections,
        picker: (_) async {
          pickerCalls++;
          return null;
        },
        onResult: (id, {files, cancelled = false, error}) async {
          completions.add((cancelled: cancelled, files: files));
        },
        onEvent: (id, type, controls, {submitter}) async {
          events.add('$id:$type');
          return false;
        },
      ),
    );
    await tester.pumpAndSettle();

    expect(pickerCalls, 1);
    expect(completions, hasLength(1));
    expect(completions.single.cancelled, isTrue);
    expect(completions.single.files, isNull);
    expect(identical(selections.get(controlId, '7')!.single, existing), isTrue);
    final widget = tester.widget<NativeHtmlFileInputWidget>(
      _fileControl(controlId),
    );
    expect(
      widget.state.filesFor(widget.control.key).single.name,
      'existing.txt',
    );
    expect(events, isEmpty);
  });

  testWidgets('replacement script document drops a pending picker result', (
    tester,
  ) async {
    const controlId = 'pirc-305';
    final oldOwner = Object();
    final newOwner = Object();
    final selections = NativeHtmlScriptFileSelections();
    final pickerResult = Completer<List<NativeHtmlFile>?>();
    final completions = <int>[];
    var supplied = false;
    final action = _action(id: 5, sequence: 55, controlId: controlId);
    List<Map<String, dynamic>> take(List<int> painted) {
      if (supplied || !painted.contains(55)) return const [];
      supplied = true;
      return [action];
    }

    await tester.pumpWidget(
      _page(
        source: '<button>Old document</button>',
        scriptDocument: oldOwner,
        actions: [action],
        take: take,
        selections: selections,
        picker: (_) => pickerResult.future,
        onResult: (id, {files, cancelled = false, error}) async {
          completions.add(id);
        },
        onEvent: (id, type, controls, {submitter}) async => false,
      ),
    );
    await tester.pump();
    expect(supplied, isTrue);

    await tester.pumpWidget(
      _page(
        source: '<button>New document</button>',
        scriptDocument: newOwner,
        actions: const [],
        take: take,
        selections: selections,
        picker: (_) async => null,
        onResult: (id, {files, cancelled = false, error}) async {
          completions.add(id);
        },
        onEvent: (id, type, controls, {submitter}) async => false,
      ),
    );
    pickerResult.complete([
      _file('stale.txt', [99]),
    ]);
    await tester.pumpAndSettle();

    expect(completions, isEmpty);
    expect(selections.get(controlId, '0'), isNull);
  });

  test('script selection registry preserves metadata and enforces limits', () {
    final selections = NativeHtmlScriptFileSelections();
    final first = _file('same.bin', [1, 2, 3], modified: 123);
    final stored = selections.store('pirc-meta', '1', [first]);
    final reselected = _file('same.bin', [1, 2, 3], modified: 999);
    final retained = selections.store('pirc-meta', '1', [reselected]);
    expect(identical(retained, stored), isTrue);
    expect(selections.get('pirc-meta', '1')!.single.lastModified, 123);

    selections.store('pirc-reset', '4', [
      _file('old.txt', [4]),
    ]);
    final state = NativeHtmlFileInputState.fromHtml(
      '<input type="file" data-pirc-script-id="pirc-reset" data-pirc-file-reset-version="5">',
      picker: (_) async => null,
    );
    addTearDown(state.dispose);
    selections.reconcile(state);
    expect(selections.get('pirc-reset', '4'), isNull);

    selections.clear();
    final half = Uint8List(NativeHtmlScriptFileSelections.maxBytes ~/ 2);
    selections.store('pirc-half-a', '0', [_file('a.bin', half)]);
    selections.store('pirc-half-b', '0', [_file('b.bin', half)]);
    expect(
      () => selections.store('pirc-over', '0', [
        _file('over.bin', [1]),
      ]),
      throwsStateError,
    );
  });
  testWidgets(
    'over-count selection reports an error and retains previous bytes',
    (tester) async {
      const id = 'pirc-over-count';
      final selections = NativeHtmlScriptFileSelections();
      final previous = _file('previous.txt', [9]);
      selections.store(id, '0', [previous]);
      final errors = <String?>[];
      var taken = false;
      final action = _action(controlId: id, multiple: true);
      await tester.pumpWidget(
        _page(
          source: '<input type="file" multiple data-pirc-script-id="$id">',
          scriptDocument: Object(),
          actions: [action],
          selections: selections,
          take: (_) {
            if (taken) return [];
            taken = true;
            return [action];
          },
          picker: (_) async =>
              List.generate(257, (i) => _file('$i.txt', const [])),
          onResult: (id, {files, cancelled = false, error}) async {
            errors.add(error);
            expect(files, isNull);
          },
          onEvent: (id, type, controls, {submitter}) async => false,
        ),
      );
      await tester.pumpAndSettle();
      expect(errors, hasLength(1));
      expect(errors.single, contains('256'));
      expect(selections.get(id, '0'), [previous]);
    },
  );
}
