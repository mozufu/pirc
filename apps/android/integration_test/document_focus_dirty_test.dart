import 'dart:convert';
import 'dart:io' show GZipCodec;
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show debugPrintSynchronously;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:integration_test/integration_test.dart';
import 'package:pirc_mobile/live/document_navigation.dart';
import 'package:pirc_mobile/live/document_navigation_state.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_text_fields.dart';
import 'package:pirc_mobile/theme.dart';
import 'document_focus_fixture.dart';

const _expected =
    'H4sIAAAAAAAC/+2cS2/iMBCA/wryOSBKeN/a0kq9bCu12suqB5MYsGSSyHFoUcV/33HeVIWykECaHS5gO/F45rPHYxPng/iKqsAnYzJ5/HVHDGJRnz3YkLa5VOtm4DPZZDZXTd+S3FPNmWvB5Qbhzsq1qOKuA9cqGfiK2c0V9/lUsOY0UAoK9FVccSpuqacCycj4g1BL8RW7E2zJHKUzuBamqJwzBTcoOockd7xAp7h/49prMp5R4TOdnIB0fWN6f1iyMYgr+Zw7aX1x8nN9au0xLY2965TlOg6zoN1kDApA/Tb3KTTfTgUmGTfre86E7TOVFklG7UdHZI1bcNtmTppUdModm71fKyU52APkOoEQYcGDLniSrsfAxGTc1nYS3GET7nuCQg4hSdZvbVEuuIpzQ/OnLdwYieW+MWSNFNctBr2hO7pCaL3fw4p0dZDNVtAtoDv/+dA6eFRZC92brwziLaBnQ12gS+BlJkn6c2S4hy0bWoGUUN1LVvQGqrlvRFtBUDBgVhTpGIp/iiSBTMWX7FnRpUfGZrtltuPPoNtr94YGmQZTMLKfms5yl57rZ1gs6lggB67JDYGXaKyl6NiMBkI9yVB0DmFJAy3m8BJ3u6gRUa23n7sVmH8BKPJC9Y/mm6QedIEsY+H6uniq2wAdSi0FfNlxE+BnbPbXjVEO1pwoBFsnsGnRAVg7iBWxItYjsHb2Y40DsdLn194o+gwG/e6w08+BjTki10txPXGCRbKVJXuSK0auyBW5VtgTm0i2lrETci2c6+v/uBmXmP5ropLZXIJuJzDdsZ9nZqMm3aHOLJsauuQ1R9dsmfG4Gfbao+Gwi+PmVH9YJNlTVh3Ittpsj49PkSySRbLV98cmsv1BbI9ffSDZ4sl2c6vK7ec2YrjWgjpzdoYYebSPZvKHS/E4Y4tFMONEwjKq8HCU6VqqHixPiYqRZtVoHh8tIUtkiSyr4WVNpFmb+AdZFsuy9x3LqQhkASTz29X7IqDWVbxaGXV63S2853t+CPEe4XYRcA0A746RduHtIF7Ei3iPxNv/Dm+YdAvZKTzdQZ9tuxAJX2wSRsZVYFymo0bCSBgJV9NPm8i45tEWEi6T8OAgwtt4c6D+CXCqxN5Aa+s8XP8i66UCHhQ95u/3LbHVorrXNSPXH8s1V3gg1w5yRa7I9TCuw4O4fj5Uc6H59WzhE2I97wSLYC8ItkxPjGARLIK9vCs2EWwdQyfEWgDWV4PoI73hqxmjg7MOXbKcKq2wQQ06U0w2JKOioQ9/NJLDH1+yLc04kbj7/Mv9dhrni1f+DYajjdZ4QR1bMHltJVpDnhchnkTAn5k+Fq2f1tv8BXMzIdT1UgAA';
const _caseId = 'dirty-user-edit-script-focus';
dynamic _normalized(Object? value) {
  if (value is List) return value.map(_normalized).toList();
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries)
        if (!const {'timeStamp', 'scroll', 'invocation'}.contains(entry.key))
          '${entry.key}': _normalized(entry.value),
    };
  }
  return value;
}

Map<String, dynamic>? _result(NativeFetchedDocument document) {
  final source = document.scripts?.content?.text;
  if (source == null) return null;
  final text = html.parse(source).querySelector('#result')?.text ?? '';
  if (!text.startsWith('{')) return null;
  return Map<String, dynamic>.from(jsonDecode(text) as Map);
}

Future<void> _until(
  WidgetTester tester,
  NativeFetchedDocument document,
  bool Function() condition,
  String label,
) async {
  for (var i = 0; i < 240 && !condition(); i++) {
    await tester.pump(const Duration(milliseconds: 25));
  }
  expect(
    condition(),
    isTrue,
    reason: '$label ${document.scripts?.diagnostics}',
  );
  expect(tester.takeException(), isNull, reason: label);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native editor change before script blur matches real Chrome typing',
    (tester) async {
      final expected = _normalized(
        jsonDecode(utf8.decode(GZipCodec().decode(base64Decode(_expected)))),
      );
      final theme = await PircTheme.load();
      var id = 0;
      for (final width in [390.0, 860.0]) {
        for (final brightness in [Brightness.light, Brightness.dark]) {
          for (final scale in [1.0, 2.0]) {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 844);
            tester.view.viewInsets = const FakeViewPadding();
            final source = documentFocusFixture.replaceFirst(
              '</body>',
              '<script>prepareDocumentFocusCase("$_caseId");</script></body>',
            );
            final bytes = Uint8List.fromList(utf8.encode(source));
            final document = NativeFetchedDocument(
              id: ++id,
              url: 'https://example.test/dirty/$id',
              status: 200,
              bytes: bytes,
              mimeType: 'text/html',
              headers: const {},
              content: NativeHtmlDocumentContent.fromBytes(
                bytes,
                mimeType: 'text/html',
                charset: 'utf-8',
              ),
            );
            try {
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme.build(brightness),
                  home: MediaQuery(
                    data: MediaQueryData(
                      size: Size(width, 844),
                      devicePixelRatio: 1,
                      textScaler: TextScaler.linear(scale),
                      viewInsets: EdgeInsets.zero,
                    ),
                    child: Scaffold(
                      body: NativeFetchedDocumentView(
                        key: ValueKey(id),
                        document: document,
                        gateway: Gateway(),
                        onLink: (_) {},
                        onSubmit: (_) {},
                      ),
                    ),
                  ),
                ),
              );
              await _until(
                tester,
                document,
                () =>
                    document.scripts?.ready == true &&
                    _result(document)?['status'] == 'READY',
                'fixture ready',
              );
              await tester.pumpAndSettle();
              expect(
                FocusManager.instance.primaryFocus?.debugLabel,
                'case target',
              );
              final fieldFinder = find.byWidgetPredicate(
                (widget) =>
                    widget is NativeHtmlTextFieldWidget &&
                    widget.field.label == 'case target',
              );
              expect(fieldFinder, findsOneWidget);
              await tester.enterText(
                find.descendant(
                  of: fieldFinder,
                  matching: find.byType(EditableText),
                ),
                'x',
              );
              await tester.pump();
              final parsed = html.parse(document.scripts!.content!.text);
              final trigger = parsed
                  .querySelector('[data-case="$_caseId"]')
                  ?.attributes['data-pirc-script-id'];
              expect(trigger, isNotNull);
              // Exercise the existing host event bridge without physically refocusing
              // the trigger button. Chrome's trigger cancels mousedown for this reason.
              await document.scripts!.click(trigger!, const []);
              await _until(
                tester,
                document,
                () => _result(document)?['status'] == 'DONE',
                'script focus done',
              );
              await tester.pumpAndSettle();
              final actual = _result(document)!;
              expect(
                _normalized(actual),
                expected,
                reason: '$width/${brightness.name}/$scale',
              );
              expect(
                FocusManager.instance.primaryFocus?.debugLabel,
                'redirect focus',
              );
              final observation = jsonEncode({
                'width': width,
                'brightness': brightness.name,
                'scale': scale,
                'result': _normalized(actual),
                'nativePrimaryFocus':
                    FocusManager.instance.primaryFocus?.debugLabel,
                'input':
                    'Flutter text input client, one x; trigger uses host dispatch without physical tap',
              });
              final encoded = base64Encode(
                GZipCodec().encode(utf8.encode(observation)),
              );
              const size = 2000;
              final count = (encoded.length + size - 1) ~/ size;
              for (var index = 0; index < count; index++) {
                final end = (index + 1) * size < encoded.length
                    ? (index + 1) * size
                    : encoded.length;
                debugPrintSynchronously(
                  'DOCUMENT_FOCUS_DIRTY_CHUNK ${jsonEncode({'document': id, 'index': index, 'total': count, 'data': encoded.substring(index * size, end)})}',
                );
              }
            } finally {
              final scripts = document.scripts;
              await tester.pumpWidget(const SizedBox.shrink());
              document.dispose();
              if (scripts != null) await scripts.closed;
            }
          }
        }
      }
      tester.view.reset();
    },
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
