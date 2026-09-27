import 'package:youtube_explode_dart/youtube_explode_dart.dart';

import '../../../../core/errors/failures.dart';
import '../../domain/playback_source.dart';
import '../../domain/track.dart';
import 'stream_extractor.dart';

/// Primary extractor: asks YouTube directly through `youtube_explode_dart`.
///
/// Audio-only streams are preferred (roughly a third of the bandwidth of the
/// muxed 360p streams) with AAC/MP4a chosen ahead of Opus because ExoPlayer
/// needs no extra decoder for it. If YouTube only offers muxed streams, those
/// are used rather than failing.
class YoutubeExtractor implements StreamExtractor {
  YoutubeExtractor(this._youtube);

  final YoutubeExplode _youtube;

  @override
  MediaSourceKind get kind => MediaSourceKind.youtube;

  @override
  String get label => 'YouTube';

  @override
  Future<PlaybackSource> extract(Track track) async {
    final StreamManifest manifest;
    try {
      manifest = await _youtube.videos.streamsClient.getManifest(track.id);
    } catch (error) {
      throw ExtractionFailure(
        'YouTube manifest lookup failed: $error',
        source: kind,
        cause: error,
      );
    }

    final audio = manifest.audioOnly;
    if (audio.isNotEmpty) {
      final best = _bestAudio(audio);
      return PlaybackSource.youtube(
        url: best.url,
        codec: best.audioCodec,
        bitrate: best.bitrate.bitsPerSecond,
        qualityLabel: best.qualityLabel,
      );
    }

    // No audio-only variant: fall back to the (video+battle-tested) muxed
    // streams, capped at 360p by YouTube, which still plays fine in the
    // background and costs a little more bandwidth.
    final muxed = manifest.muxed;
    if (muxed.isEmpty) {
      throw NoPlayableStreamFailure(
        'YouTube reported no audio streams for this track',
        source: kind,
      );
    }
    final bestMuxed = muxed.reduce(
      (a, b) => a.bitrate.bitsPerSecond >= b.bitrate.bitsPerSecond ? a : b,
    );
    return PlaybackSource.youtube(
      url: bestMuxed.url,
      codec: bestMuxed.audioCodec,
      bitrate: bestMuxed.bitrate.bitsPerSecond,
      qualityLabel: bestMuxed.qualityLabel,
    );
  }

  /// Highest bitrate wins, with a tie-break in favour of AAC so that the
  /// platform decoder is always available.
  static AudioOnlyStreamInfo _bestAudio(List<AudioOnlyStreamInfo> streams) {
    final aac =
        streams
            .where((s) => s.audioCodec.toLowerCase().contains('mp4a'))
            .toList()
          ..sort(_byDescendingBitrate);
    if (aac.isNotEmpty) return aac.first;
    return streams.reduce(
      (a, b) => a.bitrate.bitsPerSecond >= b.bitrate.bitsPerSecond ? a : b,
    );
  }

  static int _byDescendingBitrate(
    AudioOnlyStreamInfo a,
    AudioOnlyStreamInfo b,
  ) => b.bitrate.bitsPerSecond.compareTo(a.bitrate.bitsPerSecond);
}
