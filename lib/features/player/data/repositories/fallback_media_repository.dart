import '../../../../core/config/app_config.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/retry_policy.dart';
import '../../domain/media_repository.dart';
import '../../domain/playback_source.dart';
import '../../domain/search_results.dart';
import '../../domain/track.dart';
import '../extractors/extractor_chain.dart';
import '../sources/search_source.dart';

/// Applies the YouTube -> Piped fallback rule to both search and stream
/// resolution, with per-source retries in front of each attempt.
///
/// The design goal is that a dead provider adds *latency*, not an error screen:
/// every source is tried before anything is reported as failed, and the
/// individual failures travel with the exception so the UI can explain exactly
/// what was attempted.
class FallbackMediaRepository implements MediaRepository {
  FallbackMediaRepository({
    required List<SearchSource> searchSources,
    required ExtractorChain extractorChain,
    this.attemptsPerSource = AppConfig.attemptsPerSource,
    this.baseDelay = AppConfig.retryBaseDelay,
    this.maxDelay = AppConfig.retryMaxDelay,
  }) : assert(searchSources.isNotEmpty, 'at least one search source needed'),
       _searchSources = List<SearchSource>.unmodifiable(searchSources),
       _chain = extractorChain;

  final List<SearchSource> _searchSources;
  final ExtractorChain _chain;
  final int attemptsPerSource;
  final Duration baseDelay;
  final Duration maxDelay;

  /// Health of the extraction sources, for the diagnostics section of settings.
  List<ExtractorStatus> get extractorStatuses => _chain.statuses;

  @override
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  }) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      return const SearchResults(tracks: [], source: MediaSourceKind.youtube);
    }

    // A continuation token can only be replayed by the provider that issued it.
    final issuer = continuationSource(continuation);
    final candidates = issuer == null
        ? _searchSources
        : _searchSources
              .where((source) => source.kind == issuer)
              .toList(growable: false);

    if (candidates.isEmpty) {
      throw InvalidStateFailure(
        'No source available to continue the previous search',
      );
    }

    final token = continuation == null ? null : untagContinuation(continuation);
    final failures = <TaroFailure>[];

    for (final source in candidates) {
      try {
        return await withRetry(
          () => source.search(trimmed, continuation: token, filter: filter),
          maxAttempts: attemptsPerSource,
          baseDelay: baseDelay,
          maxDelay: maxDelay,
        );
      } catch (error) {
        failures.add(_asFailure(error, source.kind));
      }
    }

    throw AllSourcesFailedFailure(
      'Nothing could answer the search "$trimmed"',
      failures: failures,
    );
  }

  @override
  Future<PlaybackSource> resolveSource(Track track) => _chain.resolve(track);

  @override
  void noteRefused(Track track) => _chain.noteRefused(track);

  static TaroFailure _asFailure(Object error, MediaSourceKind kind) =>
      error is TaroFailure
      ? error
      : ExtractionFailure('$kind failed: $error', source: kind, cause: error);
}
