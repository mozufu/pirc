// Whether the app runs on Android, without importing `dart:io` on Web.
export 'platform_android_stub.dart'
    if (dart.library.io) 'platform_android_io.dart';
