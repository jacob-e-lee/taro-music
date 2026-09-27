import '../../../../core/errors/failures.dart';
import '../../domain/playback_source.dart';
import '../../domain/track.dart';

/// A provider that can turn a [Track] into something actually playable.
///
/// Every implementation must be safe to call concurrently and must throw a
/// [TaroFailure] (never a raw string) so the chain can classify the error and
/// decide whether to retry the same source or move on.
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
}
