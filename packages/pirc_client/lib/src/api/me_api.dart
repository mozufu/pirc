import 'package:meta/meta.dart';

import '../api_client.dart';
import '../json.dart';

/// The signed-in user as pots and the drawer show them.
///
/// Provisional: `/api/me` comes with M7 step 0.
@immutable
class UserProfile {
  const UserProfile({
    this.displayName = '',
    this.avatarColor = 1,
    this.avatarImage,
    this.revision = 0,
  });

  factory UserProfile.fromJson(Object? json) => UserProfile(
    displayName: str(field(json, 'displayName')) ?? '',
    avatarColor: number(field(json, 'avatarColor')) ?? 1,
    avatarImage: str(field(json, 'avatarImage')),
    revision: number(field(json, 'revision')) ?? 0,
  );

  /// The name pots call the user by.
  final String displayName;

  /// 1–5 (`avatar.<n>`).
  final int avatarColor;

  /// An image ID for `GET /api/images/{id}`.
  final String? avatarImage;

  /// Sent back with every change; a stale one is answered 409.
  final int revision;
}

/// `GET|PATCH /api/me`. Provisional: the route comes with M7 step 0.
class MeApi {
  const MeApi(this.api);
  final ApiClient api;

  // The reply wraps the profile in `profile`.
  UserProfile _profile(Object? reply) =>
      UserProfile.fromJson(field(reply, 'profile'));

  Future<UserProfile> read() async => _profile(await api.get('/api/me'));

  /// Changes the given fields. [removeAvatarImage] sends `avatarImage: null`.
  Future<UserProfile> update({
    required int revision,
    String? displayName,
    int? avatarColor,
    String? avatarImage,
    bool removeAvatarImage = false,
  }) async {
    assert(avatarImage == null || !removeAvatarImage);
    return _profile(
      await api.patch('/api/me', {
        'revision': revision,
        'displayName': ?displayName,
        'avatarColor': ?avatarColor,
        if (removeAvatarImage)
          'avatarImage': null
        else
          'avatarImage': ?avatarImage,
      }),
    );
  }
}
