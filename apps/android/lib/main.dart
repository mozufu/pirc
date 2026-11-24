import 'package:flutter/material.dart';
import 'theme.dart';
import 'package:pirc_render/src/licenses.dart';
import 'package:pirc_render/src/native_raster_images.dart';
import 'live/app.dart';
import 'live/gateway.dart';
import 'live/render_host_adapter.dart';
import 'live/scoped_gateway.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installAppRenderHost();
  registerNativeRendererLicenses();
  final theme = await PircTheme.load();
  await NativeRasterImages.loadCapabilities();
  runApp(
    MobileApp(
      theme: theme,
      controller: LiveController(DartScopedGateway(Gateway())),
    ),
  );
}
