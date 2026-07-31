/// Builds Immich media URLs and supplies the auth headers to fetch them.
/// Two implementations: [ImmichService] (x-api-key, for normal browsing) and
/// [BearerMediaSource] (session token, for Locked Folder assets).
abstract class MediaSource {
  String thumbUrl(String assetId);
  String previewUrl(String assetId);
  String originalUrl(String assetId);
  String videoUrl(String assetId);
  Map<String, String> get authHeaders;
}

/// URL builders shared by both auth modes.
mixin ImmichUrls {
  String get baseUrl;

  String thumbUrl(String id) => '$baseUrl/api/assets/$id/thumbnail?size=thumbnail';
  String previewUrl(String id) => '$baseUrl/api/assets/$id/thumbnail?size=preview';
  String originalUrl(String id) => '$baseUrl/api/assets/$id/original';
  String videoUrl(String id) => '$baseUrl/api/assets/$id/video/playback';
}

/// Media source authenticated with a session Bearer token (Locked Folder).
class BearerMediaSource with ImmichUrls implements MediaSource {
  @override
  final String baseUrl;
  final String token;
  BearerMediaSource(this.baseUrl, this.token);

  @override
  Map<String, String> get authHeaders => {'Authorization': 'Bearer $token'};
}
