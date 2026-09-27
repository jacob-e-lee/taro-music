import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../core/errors/failures.dart';
import '../../domain/playback_source.dart';
import '../../domain/track.dart';
import 'stream_extractor.dart';
import 'stream_probe.dart';

/// One Innertube client plus the label used in logs and failure messages.
///
/// The labels are not decoration: `youtube_explode_dart` calls both clients
/// below `ANDROID` in their payloads, which says nothing about *which* one a
/// listener should blame when YouTube starts refusing its URLs.
class YoutubeClientProfile {
  const YoutubeClientProfile(this.label, this.client);

  final String label;
  final YoutubeApiClient client;

  @override
  String toString() => label;
}

/// Fetches a manifest for [videoId] using exactly [client].
typedef YoutubeManifestLoader =
    Future<StreamManifest> Function(String videoId, YoutubeApiClient client);

/// Primary extractor: asks YouTube directly through `youtube_explode_dart`.
///
/// Streaming works like this: a signed URL is only valid for the client that
/// asked for it, and YouTube quietly refuses (`HTTP 403`) the URLs of whatever
/// client it is currently gating. The gate moves: in September 2026 the
/// package's default client (`androidSdkless`) still worked for ordinary
/// videos, but every music-label upload — i.e. most of what this app plays —
/// came back `403`, while the `androidVr` client served the very same video
/// fine. So instead of trusting one client, the extractor asks each candidate
/// in turn and *downloads the first byte* of what they offer: a URL that
/// answers `206` is proof, and a URL that merely parses is not.
///
/// Within one client's manifest the candidates are ordered by what the phone
/// pays for them: AAC audio-only first (ExoPlayer needs no extra decoder for
/// it), then the other audio-only renditions, then the muxed 360p stream that
/// costs bandwidth but beats silence when only the audio-only renditions are
/// gated.
class YoutubeExtractor implements StreamExtractor {
  YoutubeExtractor(
    YoutubeExplode youtube, {
    required this._probe,
    List<YoutubeClientProfile>? clients,
    YoutubeManifestLoader? loadManifest,
  }) : _clients = List<YoutubeClientProfile>.unmodifiable(
         clients ?? defaultClients,
       ),
       _loadManifest = loadManifest ?? _loaderFor(youtube),
       assert(
         (clients ?? defaultClients).isNotEmpty,
         'at least one Innertube client is required',
       );

  /// Tried in this order until one produces a URL that actually downloads.
  ///
  /// `android_vr` leads because YouTube does not (yet) make it carry a
  /// `PO token`, which is exactly what the default `android_sdkless` client is
  /// missing when it is handed label music.
  static const List<YoutubeClientProfile> defaultClients =
      <YoutubeClientProfile>[
        YoutubeClientProfile('android_vr', YoutubeApiClient.androidVr),
        YoutubeClientProfile('android_sdkless', YoutubeApiClient.androidSdkless),
      ];

  /// How many of a client's streams are worth probing before writing that
  /// client off. Each probe costs one byte, but a gated client refuses every
  /// tag it offers, so a couple of tries is all the information there is.
  static const int maxCandidatesPerClient = 3;

  final StreamProbe _probe;
  final List<YoutubeClientProfile> _clients;
  final YoutubeManifestLoader _loadManifest;

  /// Index into [_clients] of the client that last produced a playable URL.
  /// Trying it first keeps the happy path at one manifest lookup plus one byte.
  int _preferredIndex = 0;

  @override
  MediaSourceKind get kind => MediaSourceKind.youtube;

  @override
  String get label => 'YouTube';

  /// The client currently trusted first; exposed for the diagnostics screen.
  YoutubeClientProfile get preferredClient => _clients[_preferredIndex];

  @override
  Future<PlaybackSource> extract(Track track) async {
    final refusals = <String>[];
    final unreachable = <String>[];
    final lookupFailures = <String>[];

    for (final index in _order()) {
      final profile = _clients[index];

      final StreamManifest manifest;
      try {
        manifest = await _loadManifest(track.id, profile.client);
      } catch (error) {
        lookupFailures.add('${profile.label}: $error');
        continue;
      }

      for (final candidate in _candidates(manifest)) {
        final source = _sourceFor(candidate);
        final result = await _probe.check(source);
        switch (result) {
          case StreamProbeOk():
            _preferredIndex = index;
            return source;
          case StreamProbeRejected(:final detail):
            refusals.add('${profile.label}/${candidate.tag}: $detail');
          case StreamProbeUnreachable(:final detail):
            unreachable.add('${profile.label}/${candidate.tag}: $detail');
        }
      }
    }

    if (refusals.isNotEmpty) {
      throw NoPlayableStreamFailure(
        'YouTube refused to serve "${track.title}" '
        '(${refusals.join(', ')})',
        source: kind,
      );
    }
    if (unreachable.isNotEmpty) {
      throw NetworkFailure(
        'YouTube never answered for "${track.title}" '
        '(${unreachable.join(', ')})',
        source: kind,
      );
    }
    throw ExtractionFailure(
      'Could not ask YouTube for "${track.title}" '
      '(${lookupFailures.join(', ')})',
      source: kind,
    );
  }

  /// Client indices, starting with the one that worked last time.
  Iterable<int> _order() sync* {
    for (var offset = 0; offset < _clients.length; offset++) {
      yield (_preferredIndex + offset) % _clients.length;
    }
  }

  static YoutubeManifestLoader _loaderFor(YoutubeExplode youtube) =>
      (String videoId, YoutubeApiClient client) =>
          youtube.videos.streamsClient.getManifest(
            videoId,
            // Exactly one client per call: the package merges the streams of
            // every client it is handed into a single manifest, which would
            // make it impossible to tell whose URL was refused.
            ytClients: <YoutubeApiClient>[client],
          );

  /// The streams worth probing, best first (see the class doc).
  static List<StreamInfo> _candidates(StreamManifest manifest) {
    final aac = manifest.audioOnly.where(_isAac).toList()..sort(_byBitrate);
    final rest = manifest.audioOnly
        .where((stream) => !_isAac(stream))
        .toList()
      ..sort(_byBitrate);
    final muxed = manifest.muxed.toList()..sort(_byBitrate);
    return <StreamInfo>[...aac, ...rest, ...muxed]
        .take(maxCandidatesPerClient)
        .toList(growable: false);
  }

  /// ExoPlayer plays AAC without a plug-in; Opus and Vorbis it decodes in
  /// software, which is why they are only used when AAC is not on offer.
  static bool _isAac(AudioOnlyStreamInfo stream) =>
      stream.audioCodec.toLowerCase().contains('mp4a');

  static int _byBitrate(StreamInfo a, StreamInfo b) =>
      b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);

  static PlaybackSource _sourceFor(StreamInfo stream) => PlaybackSource.youtube(
    url: stream.url,
    codec: stream is AudioStreamInfo ? stream.audioCodec : null,
    bitrate: stream.bitrate.bitsPerSecond,
    qualityLabel: stream.qualityLabel,
  );
}

