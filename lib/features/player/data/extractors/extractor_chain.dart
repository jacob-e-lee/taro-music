import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/config/app_config.dart';
import '../../../../core/errors/failures.dart';
import '../../../../core/utils/retry_policy.dart';
import '../../domain/playback_source.dart';
import '../../domain/track.dart';
import 'stream_extractor.dart';

/// An [StreamExtractor] plus the [CircuitBreaker] that shields it.
class GuardedExtractor {
  GuardedExtractor(this.extractor, {CircuitBreaker? breaker})
    : breaker = breaker ?? CircuitBreaker();

  final StreamExtractor extractor;
  final CircuitBreaker breaker;

  MediaSourceKind get kind => extractor.kind;
}

/// Snapshot of a source's health, for the diagnostics list on the settings
/// screen.
class ExtractorStatus {
  const ExtractorStatus({
    required this.label,
    required this.kind,
    required this.open,
    required this.consecutiveFailures,
    this.remainingCooldown,
  });

  final String label;
  final MediaSourceKind kind;
  final bool open;
  final int consecutiveFailures;
  final Duration? remainingCooldown;
}

/// Tries each extractor in order until one produces a playable URL.
///
/// Ordering is dynamic: the source that *surfaced* a track is tried first
/// (it most likely has the stream), then the remaining sources in priority
/// order. Each source gets [attemptsPerSource] tries with exponential backoff
/// for transient errors only, and after enough consecutive failures its
/// circuit breaker takes it out of rotation for a cooldown period. This is the
/// mechanism that keeps a dead Piped mirror from adding 20 seconds of latency
/// to every song.
class ExtractorChain {
  ExtractorChain(
    List<StreamExtractor> extractors, {
    this.attemptsPerSource = AppConfig.attemptsPerSource,
    this.baseDelay = AppConfig.retryBaseDelay,
    this.maxDelay = AppConfig.retryMaxDelay,
  }) : _entries = <GuardedExtractor>[
         for (final extractor in extractors) GuardedExtractor(extractor),
       ];

  final int attemptsPerSource;
  final Duration baseDelay;
  final Duration maxDelay;
  final List<GuardedExtractor> _entries;

  List<ExtractorStatus> get statuses => <ExtractorStatus>[
    for (final entry in _entries)
      ExtractorStatus(
        label: entry.extractor.label,
        kind: entry.kind,
        open: entry.breaker.isOpen,
        consecutiveFailures: entry.breaker.consecutiveFailures,
        remainingCooldown: entry.breaker.remainingCooldown,
      ),
  ];

  Future<PlaybackSource> resolve(Track track) async {
    final failures = <TaroFailure>[];

    for (final entry in _orderedFor(track)) {
      if (entry.breaker.isOpen) {
        failures.add(
          NetworkFailure(
            '${entry.extractor.label} is cooling down '
            '(${entry.breaker.consecutiveFailures} recent failures)',
            source: entry.kind,
          ),
        );
        continue;
      }

      try {
        return await withRetry(
          () => entry.extractor.extract(track),
          maxAttempts: attemptsPerSource,
          baseDelay: baseDelay,
          maxDelay: maxDelay,
          retryOn: _isTransient,
          breaker: entry.breaker,
        );
      } catch (error) {
        // Nothing playable here: move to the next source.
        failures.add(_asFailure(error, entry));
      }
    }

    throw AllSourcesFailedFailure(
      'Could not find a playable stream for "${track.title}" '
      'by ${track.artist}',
      failures: failures,
    );
  }

  /// Tells every extractor that the player refused what they last handed out.
  ///
  /// Each extractor advances whatever cursor it has (Innertube client, Piped
  /// instance), so the next [resolve] returns a genuinely different URL rather
  /// than the same gated one.
  void noteRefused(Track track) {
    for (final entry in _entries) {
      try {
        entry.extractor.noteRefused(track);
      } on Object catch (error) {
        // A misbehaving hook must never break playback recovery.
        debugPrint('noteRefused failed for ${entry.extractor.label}: $error');
      }
    }
  }

  /// The hinted source first, everything else in its declared order.
  List<GuardedExtractor> _orderedFor(Track track) {
    final preferred = <GuardedExtractor>[];
    final rest = <GuardedExtractor>[];
    for (final entry in _entries) {
      (entry.kind == track.source ? preferred : rest).add(entry);
    }
    return <GuardedExtractor>[...preferred, ...rest];
  }

  /// Permanent answers are not worth retrying against the same provider.
  static bool _isTransient(Object error) => switch (error) {
    final NoPlayableStreamFailure _ => false,
    final InvalidStateFailure _ => false,
    final TaroFailure _ => true,
    final DioException _ => true,
    final TimeoutException _ => true,
    final Exception _ => true,
    _ => false, // Error subclasses are bugs, never retried.
  };

  static TaroFailure _asFailure(Object error, GuardedExtractor entry) {
    final label = entry.extractor.label;
    return switch (error) {
      final TaroFailure failure => failure,
      final DioException e => NetworkFailure(
        '$label: ${e.message ?? e.type.name}',
        source: entry.kind,
        cause: e,
      ),
      final Object e => ExtractionFailure(
        '$label: $e',
        source: entry.kind,
        cause: e,
      ),
    };
  }
}
