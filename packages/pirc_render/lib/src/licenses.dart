import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Include the adapted renderer's source notice in the installed app as well
/// as the repository. Loading is deferred until Flutter's license page reads it.
void registerNativeRendererLicenses() {
  LicenseRegistry.addLicense(() async* {
    final text = await rootBundle.loadString(
      'packages/pirc_render/assets/d3-sankey-license.txt',
    );
    yield LicenseEntryWithLineBreaks(const ['d3-sankey'], text);
  });
}
