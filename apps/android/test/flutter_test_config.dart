import 'dart:async';

import 'package:pirc_mobile/live/render_host_adapter.dart';

/// Every test runs with the app's renderer host and catalog, as `main()` does.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  installAppRenderHost();
  await testMain();
}
