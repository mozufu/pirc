import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/l10n/app_i18n.dart';
import 'package:pirc_mobile/live/gateway.dart';

PlatformException _http(int status, String code, String message) =>
    PlatformException(
      code: 'HTTP_$status',
      message: message,
      details: {'status': status, 'code': code},
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  tearDown(() => AppI18n.instance.setLanguage('en'));

  test('a request-shape refusal asks the user to update the app', () {
    final error = _http(
      415,
      'request_shape_required',
      'State-changing requests must be JSON or send the X-Pirc-Request header',
    );
    AppI18n.instance.setLanguage('en');
    expect(
      LiveController.describe(error),
      'This version of the app is out of date. Update the app, then try again.',
    );
    AppI18n.instance.setLanguage('zh-TW');
    expect(LiveController.describe(error), '此版本的 App 已過期，請更新 App 後再試。');
  });

  test('other 415 responses keep the server message', () {
    AppI18n.instance.setLanguage('en');
    expect(
      LiveController.describe(_http(415, 'unsupported_media', 'No such type')),
      'No such type',
    );
  });
}
