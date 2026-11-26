/// Gateway API models, transport, timeline reducer and repositories.
///
/// Platform adapters are not exported: [createTransport] picks the browser or
/// the `dart:io` one by conditional import.
library;

export 'src/api/activity_api.dart';
export 'src/api/calendar_api.dart';
export 'src/api/clients_api.dart';
export 'src/api/decisions_api.dart';
export 'src/api/device_api.dart';
export 'src/api/directory_api.dart';
export 'src/api/environment_api.dart';
export 'src/api/images_api.dart';
export 'src/api/management_api.dart';
export 'src/api/me_api.dart';
export 'src/api/memory_api.dart';
export 'src/api/modes_api.dart';
export 'src/api/models_api.dart';
export 'src/api/pairing_api.dart';
export 'src/api/pots_api.dart';
export 'src/api/providers_api.dart';
export 'src/api/push_api.dart';
export 'src/api/sessions_api.dart';
export 'src/api/threads_api.dart';
export 'src/api/usage_api.dart';
export 'src/api_client.dart';
export 'src/commands/command_sender.dart';
export 'src/commands/control.dart';
export 'src/commands/first_send.dart';
export 'src/commands/ids.dart';
export 'src/errors.dart';
export 'src/events/event_stream.dart';
export 'src/events/hint_stream.dart';
export 'src/models/api_error.dart';
export 'src/models/binding.dart';
export 'src/models/capabilities.dart';
export 'src/models/command.dart';
export 'src/models/control_lease.dart';
export 'src/models/cursor.dart';
export 'src/models/event_message.dart';
export 'src/models/preparation.dart';
export 'src/models/session.dart';
export 'src/models/snapshot.dart';
export 'src/timeline/events.dart';
export 'src/timeline/pi_messages.dart' show piMessage;
export 'src/timeline/reducer.dart';
export 'src/timeline/snapshot_state.dart';
export 'src/timeline/types.dart';
export 'src/transport/create_transport.dart';
export 'src/transport/policy.dart' show errorFor, checked, isManagementPath;
export 'src/transport/transport.dart';

/// The Gateway API version this client speaks (`GET /api/capabilities`).
const int apiVersion = 2;

/// The application name sent in `X-Pirc-Client`.
const String clientApp = 'pirc-app';

/// The `X-Pirc-Client` header value: `<app>/<apiVersion>`.
String clientHeaderValue({String app = clientApp, int version = apiVersion}) =>
    '$app/$version';
