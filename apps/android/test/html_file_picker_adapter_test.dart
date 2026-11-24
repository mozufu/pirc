import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/html_file_picker.dart';
import 'package:pirc_render/src/html_file.dart';

class _PickerGateway extends Gateway {
  final calls = <(String, Json)>[];
  Future<dynamic> Function(String method, Json args)? handler;

  @override
  Future<dynamic> call(String method, [Json args = const <String, dynamic>{}]) {
    calls.add((method, Map<String, dynamic>.of(args)));
    return handler?.call(method, args) ?? Future<dynamic>.value(null);
  }
}

const _request = NativeHtmlFilePickerRequest(
  accept: <String>['.txt', 'image/*'],
  multiple: true,
);

void main() {
  test(
    'forwards multiple and accept hints and preserves non-UTF8 bytes',
    () async {
      final gateway = _PickerGateway();
      final rawBytes = Uint8List.fromList(<int>[
        0,
        0x41,
        0xff,
        0x0d,
        0x0a,
        0x80,
      ]);
      gateway.handler = (method, args) async {
        expect(method, 'pickAttachments');
        expect(args, <String, dynamic>{
          'multiple': true,
          'accept': <String>['.txt', 'image/*'],
        });
        return <Object?>[
          <String, Object?>{
            'name': r'C:\fakepath\one résumé.bin',
            'mimeType': 'application/octet-stream',
            'bytes': rawBytes,
          },
          <String, Object?>{
            'name': 'two.txt',
            'mimeType': 'text/plain',
            'base64': base64Encode(<int>[0xfe, 0, 0x61]),
          },
        ];
      };

      final picked = await createNativeHtmlFilePicker(gateway)(_request);

      expect(gateway.calls.single.$1, 'pickAttachments');
      expect(picked, isA<List<NativeHtmlFile>>());
      final files = picked!;
      expect(files.map((file) => file.name), <String>[
        'one résumé.bin',
        'two.txt',
      ]);
      expect(files.map((file) => file.mimeType), <String>[
        'application/octet-stream',
        'text/plain',
      ]);
      expect(files.first.bytes, <int>[0, 0x41, 0xff, 0x0d, 0x0a, 0x80]);
      expect(files.last.bytes, <int>[0xfe, 0, 0x61]);

      rawBytes[0] = 0x7f;
      expect(files.first.bytes.first, 0);
    },
  );

  test(
    'passes single-selection and keeps cancellation distinct from empty result',
    () async {
      final gateway = _PickerGateway();
      dynamic response;
      gateway.handler = (method, args) async {
        expect(method, 'pickAttachments');
        expect(args, <String, dynamic>{
          'multiple': false,
          'accept': <String>['application/pdf'],
        });
        return response;
      };
      final picker = createNativeHtmlFilePicker(gateway);
      const request = NativeHtmlFilePickerRequest(
        accept: <String>['application/pdf'],
        multiple: false,
      );

      expect(
        await picker(request),
        isNull,
        reason: 'null means picker canceled',
      );
      response = <Object?>[];
      expect(
        await picker(request),
        isEmpty,
        reason: 'empty list is a completed empty selection',
      );
      expect(gateway.calls, hasLength(2));
    },
  );

  test(
    'discarded scope never opens the picker or returns a late result',
    () async {
      final gateway = _PickerGateway();
      var current = false;
      final picker = createNativeHtmlFilePicker(
        gateway,
        isCurrent: () => current,
      );

      expect(await picker(_request), isNull);
      expect(gateway.calls, isEmpty);

      current = true;
      final pending = Completer<dynamic>();
      gateway.handler = (method, args) => pending.future;
      final result = picker(_request);
      expect(gateway.calls, hasLength(1));
      current = false;
      pending.complete(<Object?>[
        <String, Object?>{
          'name': 'late.bin',
          'mimeType': 'application/octet-stream',
          'bytes': Uint8List.fromList(<int>[1, 2, 3]),
        },
      ]);

      expect(await result, isNull);
    },
  );

  test(
    'late picker failures are suppressed after the owning scope closes',
    () async {
      final gateway = _PickerGateway();
      final pending = Completer<dynamic>();
      var current = true;
      gateway.handler = (method, args) => pending.future;
      final picker = createNativeHtmlFilePicker(
        gateway,
        isCurrent: () => current,
      );
      final result = picker(_request);
      current = false;
      pending.completeError(StateError('late native picker failure'));

      expect(await result, isNull);
    },
  );

  test(
    'rejects malformed byte payloads instead of corrupting file content',
    () async {
      final gateway = _PickerGateway()
        ..handler = (method, args) async => <Object?>[
          <String, Object?>{
            'name': 'bad.bin',
            'mimeType': 'application/octet-stream',
            'bytes': <int>[0, 256],
          },
        ];
      final picker = createNativeHtmlFilePicker(gateway);

      await expectLater(picker(_request), throwsFormatException);
    },
  );
}
