import '../api_client.dart';
import '../json.dart';
import '../transport/policy.dart';
import '../transport/transport.dart';

/// `/api/images`: avatar pictures kept by the Gateway.
///
/// Provisional: the routes come with M7 step 0.
class ImagesApi {
  const ImagesApi(this.api);
  final ApiClient api;

  /// The path that serves an image to its owner.
  static String path(String id) => '/api/images/${Uri.encodeComponent(id)}';

  /// Stores a PNG, JPEG or WebP picture (at most 1 MiB) and returns its ID.
  Future<String> upload(
    List<int> bytes, {
    String contentType = 'application/octet-stream',
  }) async {
    final reply = await api.json(
      ApiRequest('POST', '/api/images', bytes: bytes, contentType: contentType),
    );
    return text(field(reply, 'imageId')) ?? '';
  }

  /// The image bytes; throws the typed error for a non-2xx reply.
  Future<List<int>> read(String id) async =>
      checked(await api.send(ApiRequest.get(path(id)))).body;
}
