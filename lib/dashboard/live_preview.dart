import '../services/feed_service.dart';
import '../services/playback_source.dart';
import '../services/weather_service.dart';

/// The live data a widget type can draw its editor preview from.
///
/// The browser can't reach the weather service or a Bluetooth connection, so
/// the preview is computed here and sent over — which also means the editor
/// shows what the panel would actually be showing at that moment, not an
/// approximation of it.
///
/// Everything is nullable: a preview is a nicety, and a widget asked for one
/// before its service has any data should fall back to its stand-in lines
/// rather than showing an error or nothing.
class PreviewData {
  const PreviewData({this.weather, this.feeds, this.playback});

  final WeatherService? weather;
  final FeedService? feeds;
  final PlaybackSource? playback;
}
