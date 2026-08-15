import 'media_source.dart';

/// A [MediaSource] for a single file already sitting on disk — lets a
/// shared video play through the existing [VideoPlayerScreen] unchanged.
/// Only [videoUrl] and [authHeaders] are ever called for a local file (see
/// [VideoPlayerScreen]); the rest of the interface has nothing meaningful
/// to return here, since there's no remote server behind a shared file.
class LocalFileMediaSource implements MediaSource {
  final String path;
  const LocalFileMediaSource(this.path);

  String get _fileUrl => Uri.file(path).toString();

  @override
  String videoUrl(String assetId) => _fileUrl;
  @override
  String thumbUrl(String assetId) => _fileUrl;
  @override
  String previewUrl(String assetId) => _fileUrl;
  @override
  String originalUrl(String assetId) => _fileUrl;
  @override
  Map<String, String> get authHeaders => const {};
}
