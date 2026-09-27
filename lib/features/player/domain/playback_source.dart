import 'package:flutter/foundation.dart';

import '../../../core/config/app_config.dart';
import '../../../core/errors/failures.dart';

/// A concrete, ready-to-feed audio URL for a [Track], together with the
/// headers the HTTP client must send alongside it.
///
/// YouTube media URLs are signed and expire after a few hours, so this object
/// is treated as short lived and never persisted.
@immutable
class PlaybackSource {
  const PlaybackSource({
    required this.url,
    required this.source,
    this.headers = const <String, String>{},
    this.codec,
    this.bitrate,
    this.qualityLabel,
  });

  /// A YouTube `googlevideo.com` stream. These reject requests whose
  /// `User-Agent` does not match the one used at extraction time, so the header
  /// is attached here rather than being left to the player's default.
  factory PlaybackSource.youtube({
    required Uri url,
    String? codec,
    int? bitrate,
    String? qualityLabel,
  }) => PlaybackSource(
    url: url,
    source: MediaSourceKind.youtube,
    codec: codec,
    bitrate: bitrate,
    qualityLabel: qualityLabel,
    headers: const <String, String>{
      'user-agent': AppConfig.extractionUserAgent,
    },
  );

  final Uri url;
  final MediaSourceKind source;
  final Map<String, String> headers;

  /// e.g. `mp4a.40.2` (AAC in MP4) or `opus`.
  final String? codec;

  /// Bits per second, when the provider reported it.
  final int? bitrate;
  final String? qualityLabel;

  /// HLS/DASH playlists are handled natively by just_audio on Android.
  bool get isHls =>
      url.path.endsWith('.m3u8') || (codec?.contains('m3u') ?? false);

  int get kiloBitsPerSecond => (bitrate ?? 0) ~/ 1000;

  @override
  String toString() =>
      'PlaybackSource(${source.name}, ${codec ?? 'unknown codec'}, '
      '${kiloBitsPerSecond}kbps, ${url.host})';
}
