import 'package:dart_ytmusic_api/types.dart';
import 'package:dart_ytmusic_api/yt_music.dart';
import 'package:flutter/foundation.dart';

import '../../../../core/errors/failures.dart';
import '../../domain/search_results.dart';
import '../../domain/track.dart';
import 'search_source.dart';

/// Catalogue search source: YouTube Music's curated song catalogue.
///
/// Regular YouTube search has no "songs" type — its `sp` filter only separates
/// videos from channels/playlists — so a songs slice can only be faked by
/// biasing the query (e.g. appending `official audio`). Biasing only re-ranks: lyric
/// videos, unofficial uploads and music videos still match. YouTube Music *is*
/// the catalogue where that decision is already made, so strict "actual songs"
/// means asking it instead of filtering harder.
///
/// `YTMusic` is a process-wide singleton (`factory YTMusic()` always returns
/// the same instance) whose `initialize()` fetches visitor config from
/// music.youtube.com. The first [search] pays that one round trip; concurrent
/// searches share the same init future, and `hasInitialized` short-circuits
/// every call after that. There is no `close()` to call — the singleton owns
/// its own `http.Client` for the life of the process.
///
/// Songs only: song search is effectively one page, so [SearchResults] is
/// returned without a continuation and "load more" simply ends. Callers must
/// check [SearchSource.supportsScope] — this source throws
/// [InvalidStateFailure] for [SearchScope.videos] instead of answering wrongly.
class YTMusicSearchSource implements SearchSource {
  YTMusicSearchSource({YTMusic? client}) : _client = client ?? YTMusic();

  final YTMusic _client;

  /// Shared by concurrent first-searches so `initialize()` runs exactly once.
  Future<void>? _initFuture;

  @override
  MediaSourceKind get kind => MediaSourceKind.ytmusic;

  @override
  String get label => 'YouTube Music';

  @override
  bool supportsScope(SearchScope scope) => scope == SearchScope.songs;

  @override
  Future<SearchResults> search(
    String query, {
    String? continuation,
    SearchScope filter = SearchScope.songs,
  }) async {
    if (filter != SearchScope.songs) {
      throw InvalidStateFailure(
        'YouTube Music source only serves songs, not ${filter.name}',
      );
    }
    if (continuation != null && continuation.isNotEmpty) {
      // No continuation is ever issued below, so a token means a stale or
      // hand-built request rather than a page we can serve.
      throw const InvalidStateFailure(
        'YouTube Music song search has no further pages, please search again',
      );
    }

    final songs = await _guard(() async {
      await _ensureInitialized();
      return _client.searchSongs(query);
    });

    final tracks = songs
        .map(trackFrom)
        .whereType<Track>()
        .toList(growable: false);
    return SearchResults(tracks: tracks, source: kind);
  }

  Future<void> _ensureInitialized() {
    // A failed init must not be cached — the singleton's `hasInitialized`
    // stays false, so the next search should be allowed to try again.
    return _initFuture ??= _client.initialize().then((_) {}).catchError((
      Object error,
    ) {
      _initFuture = null;
      throw error;
    });
  }

  /// The package throws plain [Exception]s (Innertube errors, config fetch
  /// failures) rather than [TaroFailure]s; normalize them so the repository's
  /// fallback chain treats each attempt as one provider failure.
  Future<T> _guard<T>(Future<T> Function() request) async {
    try {
      return await request();
    } on TaroFailure {
      rethrow;
    } catch (error) {
      throw NetworkFailure(
        'YouTube Music search failed: $error',
        source: kind,
        cause: error,
      );
    }
  }

  /// Maps one catalogue entry; null when the entry has no playable identity.
  ///
  /// `duration` is seconds-or-null in the package: null (or non-positive)
  /// becomes [Duration.zero], which the UI renders as unknown length rather
  /// than a bogus timestamp.
  ///
  /// The largest thumbnail wins, as catalogue artwork arrives smallest-first.
  /// Note the ceiling here is 544px: that is all the API ever advertises, so
  /// this loop cannot reach the 1280px the CDN would actually serve. That is
  /// fine, because the hero opts into an upscaled url at paint time
  /// (ResilientArtwork(upscale: true)). Do not try to fix the softness by
  /// reordering this loop — it is already choosing the best of what it is given.
  @visibleForTesting
  static Track? trackFrom(SongDetailed song) {
    if (song.videoId.isEmpty) return null;
    final thumbnails = song.thumbnails;
    String? artworkUrl;
    var artworkWidth = -1;
    for (final thumb in thumbnails) {
      if (thumb.url.isEmpty) continue;
      if (thumb.width > artworkWidth) {
        artworkWidth = thumb.width;
        artworkUrl = thumb.url;
      }
    }
    final seconds = song.duration;
    return Track(
      id: song.videoId,
      title: song.name.isEmpty ? 'Unknown title' : song.name,
      artist: song.artist.name,
      album: song.album?.name,
      duration: seconds != null && seconds > 0
          ? Duration(seconds: seconds)
          : Duration.zero,
      artworkUrl: artworkUrl,
      source: MediaSourceKind.ytmusic,
    );
  }
}
