/// The upstream providers Taro Music knows how to pull music from.
enum MediaSourceKind {
  /// Direct extraction against YouTube using `youtube_explode_dart`.
  youtube,

  /// The privacy proxy (Piped) fronted by [MediaSourceKind.youtube].
  piped,
}

/// Base class for every expected error surfaced to the UI.
///
/// Anything that is not a [TaroFailure] is treated as a programming bug and is
/// allowed to crash in debug builds.
sealed class TaroFailure implements Exception {
  const TaroFailure(this.message, {this.source, this.cause});

  /// Human readable explanation, safe to show in a snack bar.
  final String message;

  /// Which upstream provider produced the failure, when applicable.
  final MediaSourceKind? source;

  /// The original error, kept for logging.
  final Object? cause;

  @override
  String toString() =>
      '$runtimeType'
      '${source == null ? '' : '(${source!.name})'}: $message';
}

/// The request never completed: DNS failure, timeout, 5xx, no connectivity.
class NetworkFailure extends TaroFailure {
  const NetworkFailure(super.message, {super.source, super.cause});
}

/// The provider answered but the metadata/stream could not be decoded.
class ExtractionFailure extends TaroFailure {
  const ExtractionFailure(super.message, {super.source, super.cause});
}

/// The provider answered but returned nothing playable for this track.
class NoPlayableStreamFailure extends TaroFailure {
  const NoPlayableStreamFailure(super.message, {super.source, super.cause});
}

/// Every source in the fallback chain failed. [failures] holds one entry per
/// attempt, which is what the "all sources failed" debug screen renders.
class AllSourcesFailedFailure extends TaroFailure {
  const AllSourcesFailedFailure(
    super.message, {
    this.failures = const <TaroFailure>[],
  });

  final List<TaroFailure> failures;

  @override
  String toString() =>
      'AllSourcesFailedFailure: $message '
      '(${failures.map((f) => f.toString()).join(' | ')})';
}

/// The user asked for an action the current state cannot satisfy, e.g. seeking
/// while nothing is loaded.
class InvalidStateFailure extends TaroFailure {
  const InvalidStateFailure(super.message);
}
