import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';

/// A block of lyric text, one entry per line.
@immutable
class Lyrics {
  const Lyrics({required this.lines});

  final List<String> lines;

  bool get isEmpty => lines.every((line) => line.trim().isEmpty);
}

/// Outcome of asking for a track's lyrics.
///
/// Modelled as a result type rather than a nullable [Lyrics] so that "we have
/// no lyrics" and "the lookup failed" can be told apart - they need different
/// copy in the UI, and only the second is worth retrying.
@immutable
sealed class LyricsResult {
  const LyricsResult();

  /// The factory used until a real source is wired up.
  const factory LyricsResult.unavailable() = LyricsUnavailable;

  const factory LyricsResult.loaded(Lyrics lyrics) = LyricsLoaded;

  const factory LyricsResult.failed(String message) = LyricsFailed;
}

final class LyricsUnavailable extends LyricsResult {
  const LyricsUnavailable();
}

final class LyricsLoaded extends LyricsResult {
  const LyricsLoaded(this.lyrics);

  final Lyrics lyrics;
}

final class LyricsFailed extends LyricsResult {
  const LyricsFailed(this.message);

  final String message;
}

/// Source of lyrics for a track.
///
/// This is a UI-only stub for now: there is no lyrics backend in the app, so
/// every lookup reports [LyricsUnavailable] and the tab renders an empty state.
/// Implementing a real source (LRCLIB is the obvious candidate - free, no API
/// key, returns synced `.lrc`) means implementing this one interface and
/// changing the provider below; nothing in the tab UI has to move.
abstract interface class LyricsSource {
  Future<LyricsResult> lyricsFor(String trackId);
}

/// The current source. Replace the body with a real implementation when one
/// lands; the rest of the app only sees [LyricsSource].
class _UnavailableLyricsSource implements LyricsSource {
  const _UnavailableLyricsSource();

  @override
  Future<LyricsResult> lyricsFor(String trackId) async =>
      const LyricsResult.unavailable();
}

final lyricsSourceProvider = Provider<LyricsSource>(
  (_) => const _UnavailableLyricsSource(),
);

/// Lyrics for [trackId].
///
/// Auto-disposes so switching tracks does not accumulate results.
final lyricsProvider = FutureProvider.autoDispose.family<LyricsResult, String>(
  (ref, trackId) => ref.watch(lyricsSourceProvider).lyricsFor(trackId),
);
