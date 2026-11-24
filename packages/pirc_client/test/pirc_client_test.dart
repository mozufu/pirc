import 'package:pirc_client/pirc_client.dart';
import 'package:test/test.dart';

void main() {
  test('client header names the app and the API version', () {
    expect(clientHeaderValue(), 'pirc-app/2');
  });
}
