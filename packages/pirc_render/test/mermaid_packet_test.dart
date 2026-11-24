import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/packet_parser.dart';
import 'package:pirc_render/src/mermaid/packet_rendering.dart';

Map<String, dynamic> _readFixture(String relativePath) {
  for (final path in [relativePath, '../../$relativePath']) {
    final file = File(path);
    if (file.existsSync()) {
      return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    }
  }
  throw StateError('Could not find fixture $relativePath');
}

Map<String, Object?> _dbSegment(dynamic value) {
  final item = value as Map<String, dynamic>;
  return {
    'start': item['start'],
    'end': item['end'],
    'bits': item['bits'],
    'label': item['label'],
  };
}

void main() {
  late Map<String, dynamic> oracle;
  late Map<String, dynamic> browserFixture;

  setUpAll(() {
    oracle = _readFixture('fixtures/mobile-parity/mermaid-packet-oracle.json');
    browserFixture = _readFixture(
      'fixtures/mobile-parity/mermaid-important-web.json',
    );
  });

  test('keeps the pinned PacketDB rows, metadata, and bit counts', () {
    expect(oracle['mermaidVersion'], '11.17.2');
    expect(oracle['oracleMode'], 'node-pinned-packet-db-parser-only');
    expect(oracle['usesChromium'], isFalse);

    for (final item in oracle['cases'] as List<dynamic>) {
      final example = item as Map<String, dynamic>;
      final diagram = parseNativeMermaidPacket(example['source'] as String);
      expect(diagram.title, example['title'], reason: example['id'] as String);
      expect(
        diagram.accessibleTitle,
        example['accessibleTitle'],
        reason: example['id'] as String,
      );
      expect(
        diagram.accessibleDescription,
        example['accessibleDescription'],
        reason: example['id'] as String,
      );

      final expectedRows = (example['rows'] as List<dynamic>)
          .map(
            (row) =>
                (row as List<dynamic>).map(_dbSegment).toList(growable: false),
          )
          .toList(growable: false);
      final nativeRows = diagram.rows
          .map(
            (row) => row.fields
                .map(
                  (field) => <String, Object?>{
                    'start': field.startBit,
                    'end': field.endBit,
                    'bits': field.bits,
                    'label': field.label,
                  },
                )
                .toList(growable: false),
          )
          .toList(growable: false);
      expect(nativeRows, expectedRows, reason: example['id'] as String);

      final config = example['config'] as Map<String, dynamic>;
      expect(diagram.config.bitsPerRow, config['bitsPerRow']);
      expect(diagram.config.bitWidth, config['bitWidth']);
      expect(diagram.config.rowHeight, config['rowHeight']);
      expect(diagram.config.paddingX, config['paddingX']);
      expect(diagram.config.effectivePaddingY, config['paddingY']);
      expect(diagram.config.showBits, config['showBits']);
      expect(diagram.config.useMaxWidth, config['useMaxWidth']);
    }
  });

  test('layout fields and text agree with the pinned Markdown SVG capture', () {
    final capture = (browserFixture['captures'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (item) =>
              item['id'] == 'packet-tcp' &&
              item['width'] == 390 &&
              item['colorScheme'] == 'light',
        );
    final diagram = parseNativeMermaidPacket(capture['source'] as String);
    final cssWidth = (capture['box']['width'] as num).toDouble();
    final layout = layoutNativeMermaidPacket(
      diagram,
      width: cssWidth,
      dark: false,
      fontFamily: 'Arial',
    );

    final viewBox = (capture['viewBox'] as String)
        .split(' ')
        .map(double.parse)
        .toList(growable: false);
    expect(layout.viewBoxSize.width, viewBox[2]);
    expect(layout.viewBoxSize.height, viewBox[3]);
    expect(layout.size.width, closeTo(cssWidth, 0.01));
    expect(
      layout.size.height,
      closeTo((capture['box']['height'] as num).toDouble(), 0.02),
    );
    expect(layout.texts.map((text) => text.text).toList(), [
      for (final item in capture['labels'] as List<dynamic>) item['text'],
    ]);

    final firstField = layout.rows.first.fields.first;
    final firstShape = (capture['shapes'] as List<dynamic>).first as Map;
    final expectedRect = firstShape['bbox'] as Map<String, dynamic>;
    expect(
      firstField.paintRect.left,
      closeTo((expectedRect['x'] as num).toDouble(), 0.001),
    );
    expect(
      firstField.paintRect.top,
      closeTo((expectedRect['y'] as num).toDouble(), 0.001),
    );
    expect(
      firstField.paintRect.width,
      closeTo((expectedRect['width'] as num).toDouble(), 0.001),
    );
    expect(
      firstField.paintRect.height,
      closeTo((expectedRect['height'] as num).toDouble(), 0.001),
    );
    expect(firstField.labelText.text, 'Source Port');
    expect(firstField.startBitText?.text, '0');
    expect(firstField.endBitText?.text, '15');
    expect(firstField.labelText.position.dx, 254.5);
    expect(firstField.labelText.position.dy, 31);
  });

  test(
    'cross-row count fields keep each row bit label and source field link',
    () {
      final item = (oracle['cases'] as List<dynamic>)
          .cast<Map<String, dynamic>>()
          .firstWhere((value) => value['id'] == 'packet-cross-row');
      final diagram = parseNativeMermaidPacket(item['source'] as String);
      final layout = layoutNativeMermaidPacket(diagram, width: 700, dark: true);

      expect(diagram.fields.map((field) => field.label), [
        'Header',
        'Cross row',
        'Payload',
      ]);
      expect(layout.rows.map((row) => row.fields.length), [2, 2]);
      expect(
        layout.rows
            .expand((row) => row.fields)
            .map((field) => '${field.startBit}-${field.endBit}:${field.label}'),
        ['0-4:Header', '5-31:Cross row', '32-47:Cross row', '48-63:Payload'],
      );
      expect(
        layout.texts
            .where((text) => text.role.startsWith('packetByte'))
            .map((text) => text.text),
        ['0', '4', '5', '31', '32', '47', '48', '63'],
      );
      expect(layout.blockFillColor, const Color(0xff333333));
      expect(layout.blockStrokeColor, const Color(0xffe0dfdf));
    },
  );

  test('applies the supported PacketDB init config and Chrome geometry', () {
    final oracleCase = (oracle['cases'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((value) => value['id'] == 'packet-configured');
    final diagram = parseNativeMermaidPacket(oracleCase['source'] as String);
    expect(diagram.config.bitsPerRow, 16);
    expect(diagram.config.bitWidth, 24);
    expect(diagram.config.rowHeight, 32);
    expect(diagram.config.showBits, isFalse);
    expect(diagram.config.paddingX, 5);
    expect(diagram.config.paddingY, 5);
    expect(diagram.config.effectivePaddingY, 5);
    expect(diagram.config.useMaxWidth, isTrue);
    expect(diagram.rows.map((row) => row.fields.length), [2, 1]);
    expect(
      diagram.rows
          .expand((row) => row.fields)
          .map((field) => '${field.startBit}-${field.endBit}:${field.label}'),
      ['0-8:Control', '9-15:Payload', '16-31:Payload'],
    );

    final capture = (browserFixture['captures'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere(
          (item) =>
              item['id'] == 'packet-configured' &&
              item['width'] == 390 &&
              item['colorScheme'] == 'light',
        );
    final layout = layoutNativeMermaidPacket(
      parseNativeMermaidPacket(capture['source'] as String),
      width: (capture['box']['width'] as num).toDouble(),
      dark: false,
      fontFamily: 'Arial',
    );
    final viewBox = (capture['viewBox'] as String)
        .split(' ')
        .map(double.parse)
        .toList(growable: false);
    expect(layout.viewBoxSize.width, viewBox[2]);
    expect(layout.viewBoxSize.height, viewBox[3]);
    expect(layout.size.width, closeTo(332, 0.01));
    expect(
      layout.size.height,
      closeTo((capture['box']['height'] as num).toDouble(), 0.02),
    );
    final capturedRects = (capture['shapes'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .map((shape) => shape['bbox'] as Map<String, dynamic>)
        .toList(growable: false);
    final fields = layout.fields.toList(growable: false);
    expect(fields.length, capturedRects.length);
    for (var index = 0; index < fields.length; index++) {
      final rect = fields[index].paintRect;
      final expected = capturedRects[index];
      expect(rect.left, closeTo((expected['x'] as num).toDouble(), 0.001));
      expect(rect.top, closeTo((expected['y'] as num).toDouble(), 0.001));
      expect(rect.width, closeTo((expected['width'] as num).toDouble(), 0.001));
      expect(
        rect.height,
        closeTo((expected['height'] as num).toDouble(), 0.001),
      );
    }
    expect(layout.texts.map((text) => text.text), [
      for (final item in capture['labels'] as List<dynamic>) item['text'],
    ]);
  });

  testWidgets('applies all packet config fields and intrinsic sizing', (
    tester,
  ) async {
    final item = (oracle['cases'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((value) => value['id'] == 'packet-init-all-fields');
    final diagram = parseNativeMermaidPacket(item['source'] as String);
    expect(diagram.config.bitsPerRow, 16);
    expect(diagram.config.bitWidth, 24);
    expect(diagram.config.showBits, isTrue);
    expect(diagram.config.rowHeight, 24);
    expect(diagram.config.paddingX, 0);
    expect(diagram.config.paddingY, 7);
    expect(diagram.config.effectivePaddingY, 17);
    expect(diagram.config.useMaxWidth, isFalse);

    final layout = layoutNativeMermaidPacket(diagram, width: 100, dark: false);
    expect(layout.viewBoxSize.width, 386);
    expect(layout.viewBoxSize.height, 123);
    expect(layout.size.width, 386);
    expect(layout.size.height, 123);
    expect(layout.rows.map((row) => row.fields.length), [2, 1]);
    expect(
      layout.rows.first.fields.first.paintRect,
      const Rect.fromLTWH(1, 17, 192, 24),
    );
    expect(
      layout.rows.last.fields.single.paintRect,
      const Rect.fromLTWH(1, 58, 192, 24),
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            child: NativeMermaidPacket(diagram: diagram, dark: false),
          ),
        ),
      ),
    );
    expect(
      tester.getSize(
        find.descendant(
          of: find.byType(NativeMermaidPacket),
          matching: find.byType(CustomPaint),
        ),
      ),
      const Size(386, 123),
    );
  });

  test(
    'invalid syntax, unsupported config, and oversized packets fail explicitly',
    () {
      final oversizedSource =
          'packet-beta\n${List<String>.filled(50001, 'x').join()}';
      for (final source in [
        'packet-beta\n+0: "zero bits"',
        'packet-beta\n1: "must start at zero"',
        'packet-beta\n0-3: "first"\n5: "gap"',
        'packet-beta\n2-1: "backwards"',
        'packet-beta\n0: unquoted',
        '%%{init: {"theme": "dark"}}%%\npacket-beta',
        '%%{init: {"packet": {"labelFontSize": 16}}}%%\npacket-beta',
        '%%{init: {"packet": {"styles": {"fill": "red"}}}}%%\npacket-beta',
        '%%{init: {"packet": {bitsPerRow: 8}}}%%\npacket-beta',
        '%%{init: {"packet": {"bitWidth": 0}}}%%\npacket-beta',
        '%%{init: {"packet": {"bitWidth": 4, "paddingX": 4}}}%%\npacket-beta',
        '%%{init: {"packet": {"bitsPerRow": 257}}}%%\npacket-beta',
        '%%{init: {"packet": {"paddingY": -1}}}%%\npacket-beta',
        '%%{init: {"packet": {"useMaxWidth": "yes"}}}%%\npacket-beta',
        '%%{theme: "dark"}%%\npacket-beta',
        'packet-beta\n%%{init: {"packet": {"bitsPerRow": 8}}}%%',
        '%%{init: {"packet": {"bitsPerRow": 8}}}%%\n'
            '%%{init: {"packet": {"bitWidth": 8}}}%%\npacket-beta',
        '---\nconfig:\n  packet:\n    bitsPerRow: 8\n---\npacket',
        oversizedSource,
      ]) {
        expect(
          () => parseNativeMermaidPacket(source),
          throwsA(isA<FormatException>()),
          reason: source.length > 100 ? 'oversized input' : source,
        );
      }
    },
  );

  testWidgets('exposes title, accessibility text, and all field labels', (
    tester,
  ) async {
    final item = (oracle['cases'] as List<dynamic>)
        .cast<Map<String, dynamic>>()
        .firstWhere((value) => value['id'] == 'packet-accessible');
    final diagram = parseNativeMermaidPacket(item['source'] as String);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 390,
            child: NativeMermaidPacket(diagram: diagram, dark: false),
          ),
        ),
      ),
    );

    expect(find.bySemanticsLabel(diagram.semanticsLabel), findsOneWidget);
    final semanticsNode = tester.getSemantics(
      find.bySemanticsLabel(diagram.semanticsLabel),
    );
    expect(semanticsNode.label, contains('Binary frame'));
    expect(semanticsNode.label, contains('Flag and payload fields'));
    expect(semanticsNode.label, contains('Bits 8–31: Payload'));
    expect(
      find.descendant(
        of: find.byType(NativeMermaidPacket),
        matching: find.byType(CustomPaint),
      ),
      findsOneWidget,
    );
    semantics.dispose();
  });
}
