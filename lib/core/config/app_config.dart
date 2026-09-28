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

  /// Fallback User-Agent for HTTP calls that are **not** bound to a signed
  /// stream URL — i.e. the Piped JSON API and YouTube's search endpoint.
  ///
  /// Signed `googlevideo.com` URLs are the opposite case: each one is bound to
  /// whichever Innertube client minted it and answers `403` to anything else.
  /// Stream URLs now always come from Piped, which chose that client for us, so
  /// they travel with [browserUserAgent] instead.
  ///
  /// The string matches the default UA of `youtube_explode_dart`'s HTTP client,
  /// so our own calls and the package's are indistinguishable to YouTube.
  static const String extractionUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/96.0.4664.18 Safari/537.36';

  /// A current desktop-browser UA, for streaming URLs minted by a proxy (Piped)
  /// rather than by one of our own Innertube clients. Those are not bound to a
  /// client we can name, so a plain browser string is the best available guess.
  static const String browserUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

  /// How long a resolved URL has to answer a [streamProbeRange] request before
  /// the extractors write it off and try the next candidate.
  static const Duration streamProbeTimeout = Duration(seconds: 8);

  /// The request used to prove a stream is playable before the player gets it.
  ///
  /// One byte is enough for `googlevideo.com` to answer `206` (playable) or
  /// `403` (the client whose URL this is has been gated), and asking for a
  /// single byte means a server that ignores `Range` still cannot make the app
  /// download a whole file to find that out. The probe sends the player's own
  /// headers, so it fails for exactly the reasons the player would.
  static const String streamProbeRange = 'bytes=0-0';

  /// The header [streamProbeRange] travels in. `dio`'s `Headers` only names
  /// accept/content-*/www-authenticate, so the name lives here.
  static const String streamProbeRangeHeader = 'range';

  /// Ordered fallback list of Piped API instances (public/community mirrors),
  /// used for both search and stream extraction.
  ///
  /// The first entry is the primary: everything else is only reached when the
  /// one before it rate-limits (429/5xx) or stops answering. Public instances
  /// come and go, so several are kept and the cursor advances on every
  /// network-level failure. The user can override this in settings later.
  static const List<String> pipedInstances = <String>[
    'https://pipedapi.kavin.rocks',
    'https://api.piped.projectsegfau.lt',
    'https://pipedapi.lunar.icu',
    'https://piped-api.garudalinux.org',
  ];

  /// Piped search filter that restricts results to playable music tracks.
  static const String pipedSearchFilter = 'music_songs';

  static const Duration httpTimeout = Duration(seconds: 15);
  static const Duration connectTimeout = Duration(seconds: 8);

  /// Ordered fallback list of Cobalt instances, most-trusted first.
  ///
  /// Cobalt answers a single stable JSON shape, so a dead instance is just a
  /// non-200 status and the extractor walks to the next one. These are
  /// volunteer/community-run with no SLA; the user can override the list in
  /// settings later.
  static const List<String> cobaltInstances = <String>[
    'https://co.wuk.sh',
    'https://api.cobalt.tools',
    'https://cobalt.q0.is',
  ];

  /// Identifies the app to Cobalt instances, which are stricter about client
  /// identity than Piped was. Honest and specific beats a spoofed browser
  /// string, which only attracts bot checks.
  static const String cobaltUserAgent = 'TaroMusic/1.0.0 (Android)';

  /// What `aFormat: best` actually yields for an audio-only request. Cobalt
  /// reports neither value, so they are stated here; they feed the player's
  /// decoder choice and the UI's bitrate label, nothing else.
  static const String cobaltCodec = 'mp4a';
  static const int cobaltBitrate = 128000;

  /// Last-resort stream endpoint, consulted only after the rotating chain has
  /// exhausted every Innertube client *and* every instance in
  /// [pipedInstances]. Public mirrors come and go, so this one is a named
  /// address to try again rather than another entry in the rotation.
  static const String directFallbackEndpoint = 'https://pipedapi.kavin.rocks';

  /// How many times a single source (e.g. one Piped instance) is retried before
  /// the chain gives up on it and moves to the next source.
  static const int attemptsPerSource = 2;

  /// Base delay for exponential backoff between retries.
  static const Duration retryBaseDelay = Duration(milliseconds: 600);
  static const Duration retryMaxDelay = Duration(seconds: 6);

  /// Search results are paged in blocks of 20 by YouTube's search endpoint.
  static const int searchPageSize = 20;
}
