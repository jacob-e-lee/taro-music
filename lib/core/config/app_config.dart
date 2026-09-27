/// Static, compile-time configuration for Taro Music.
///
/// Keeping every tunable in one place makes the later settings screen a matter
/// of overriding these defaults instead of hunting through the code base.
class AppConfig {
  const AppConfig._();

  static const String appName = 'Taro Music';

  /// Notification channel shown in Android settings.
  static const String notificationChannelId = 'com.example.taro_music.media';
  static const String notificationChannelName = 'Playback';
  static const String notificationChannelDescription =
      'Shows controls for music playing in the background';

  /// The User-Agent used while *extracting* a stream URL must be byte-for-byte
  /// identical to the one used while *playing* it, otherwise `googlevideo.com`
  /// answers the media request with HTTP 403. This string matches the default
  /// UA of `youtube_explode_dart`'s HTTP client.
  static const String extractionUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/96.0.4664.18 Safari/537.36';

  /// Ordered fallback list of Piped API instances (public/community mirrors).
  /// Public instances come and go, so several are kept and the chain tries each
  /// one until something answers. The user can override this in settings later.
  static const List<String> pipedInstances = <String>[
    'https://api.piped.private.coffee',
    'https://pipedapi.ducks.party',
    'https://pipedapi.kavin.rocks',
    'https://pipedapi.adminforge.de',
  ];

  /// Piped search filter that restricts results to playable music tracks.
  static const String pipedSearchFilter = 'music_songs';

  static const Duration httpTimeout = Duration(seconds: 15);
  static const Duration connectTimeout = Duration(seconds: 8);

  /// How many times a single source (e.g. one Piped instance) is retried before
  /// the chain gives up on it and moves to the next source.
  static const int attemptsPerSource = 2;

  /// Base delay for exponential backoff between retries.
  static const Duration retryBaseDelay = Duration(milliseconds: 600);
  static const Duration retryMaxDelay = Duration(seconds: 6);

  /// Search results are paged in blocks of 20 by YouTube's search endpoint.
  static const int searchPageSize = 20;
}
