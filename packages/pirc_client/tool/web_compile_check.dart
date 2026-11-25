// Compiled with `dart compile js` to prove the web adapter builds: the
// conditional import must pick `web_transport.dart` and pull in no `dart:io`.
import 'package:pirc_client/pirc_client.dart';

void main() {
  final transport = createTransport(TransportConfig(baseUri: Uri.base));
  print('${transport.runtimeType} ${clientHeaderValue()}');
}
