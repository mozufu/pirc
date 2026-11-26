import '../api_client.dart';
import '../errors.dart';
import '../json.dart';
import 'management_api.dart';

/// `/api/device`: the calling paired device's own record. No management grant
/// is needed; a browser has no device record.
class DeviceApi {
  const DeviceApi(this.api);
  final ApiClient api;

  Future<DeviceSummary> read() async =>
      DeviceSummary.fromJson(field(await api.get('/api/device'), 'device'));

  /// `POST /api/device/rotate`: a new token for the same device record, with
  /// new idle and maximum windows. The old token keeps working until the new
  /// one is first used or 5 minutes pass, so a lost reply can be asked again
  /// with the old token. The token is shown this once.
  Future<(DeviceSummary, String)> rotate() async {
    final reply = await api.post('/api/device/rotate');
    final token = str(field(reply, 'token')) ?? '';
    if (token.isEmpty) {
      throw const ApiError(502, 'bad_reply', 'The rotation reply has no token');
    }
    return (DeviceSummary.fromJson(field(reply, 'device')), token);
  }

  /// Renames this device; its name shows wherever it holds control.
  Future<DeviceSummary> rename(String name) async => DeviceSummary.fromJson(
    field(await api.patch('/api/device', {'name': name}), 'device'),
  );
}
