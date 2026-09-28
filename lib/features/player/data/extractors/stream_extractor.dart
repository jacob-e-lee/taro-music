import '../../../../core/errors/failures.dart';
import '../../domain/playback_source.dart';
import '../../domain/track.dart';

/// A provider that can turn a [Track] into something actually playable.
///
/// Every implementation must be safe to call concurrently and must throw a
/// [TaroFailure] (never a raw string) so the chain can classify the error and
/// decide whether to retry the same source or move on.
///
/// It must also *verify* what it returns: a [PlaybackSource] whose URL parses
/// is not the same thing as a URL that downloads, and handing the unverified
/// kind to the player produces a silent spinner rather than an error. See
/// `StreamProbe` for how that check is made.
abstract interface class StreamExtractor {
  /// The provider this extractor talks to.
  MediaSourceKind get kind;

  /// Short name for logs and the "which source served this?" debug screen.
  String get label;

  /// Resolves the best available audio stream for [track].
  ///
  /// Throws [NoPlayableStreamFailure] when the provider answered but has
  /// nothing playable (permanent for this source), or [NetworkFailure] /
  /// [ExtractionFailure] when the call itself went wrong (worth retrying).
  Future<PlaybackSource> extract(Track track);

  /// Called when the *player* refused a URL this extractor had already
  /// verified, so the next [extract] should try a different rendition.
  ///
  /// This exists because a successful probe is not proof of playability: a
  /// `Range: bytes=0-0` request can come back 206 while the player's real
  /// request is refused with a 403 (YouTube's URL gating is the common case).
  /// Without this hook a refused URL is served again forever, because from the
  /// extractor's point of view nothing ever failed.
  void noteRefused(Track track) {}
}
