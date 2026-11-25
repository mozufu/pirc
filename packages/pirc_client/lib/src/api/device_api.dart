import '../api_client.dart';
import '../json.dart';
import 'management_api.dart';

/// `/api/device`: the calling paired device's own record. No management grant
/// is needed; a browser has no device record.
class DeviceApi {
  const DeviceApi(this.api);
  final ApiClient api;

  Future<DeviceSummary> read() async =>
      DeviceSummary.fromJson(field(await api.get('/api/device'), 'device'));

  /// Renames this device; its name shows wherever it holds control.
  Future<DeviceSummary> rename(String name) async => DeviceSummary.fromJson(
    field(await api.patch('/api/device', {'name': name}), 'device'),
  );
}
