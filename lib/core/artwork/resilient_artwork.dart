import 'package:flutter/material.dart';

import 'artwork_source.dart';

/// Artwork that steps down through size tiers rather than giving up on the
/// first 404.
///
/// A plain [Image.network] gets one URL and shows its placeholder if that one
/// fails. This tries each candidate in turn and keeps the first that loads, so
/// the best available image wins and a missing tier costs one wasted request
/// rather than the whole picture.
///
/// The walk is not only a fallback mechanism. For a YouTube Music catalogue
/// url the first candidate is a deliberate *upgrade* to a larger download of
/// the same image — see [upscale] and ArtworkSource.candidates.
class ResilientArtwork extends StatefulWidget {
  const ResilientArtwork({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.fallback,
    this.providerFor,
    this.filterQuality,
    this.upscale = false,
    this.cacheWidth,
    this.cacheHeight,
  });

  final String? url;
  final double? width;
  final double? height;
  final BoxFit fit;

  /// Physical pixel width to decode the bitmap at, or null to decode at the
  /// source's own size.
  ///
  /// [width] is where the image is *drawn*; this is how much of it is actually
  /// *stored*. A 36dp queue row at 3x needs 108 physical pixels, but the
  /// catalogue url hands out 544x544 - roughly 1.1MB of RGBA per row to paint a
  /// 108px square, and opening the queue decodes a screenful of them at once on
  /// the raster thread.
  ///
  /// A decode size is permanent for that url in the [ImageCache], so this is
  /// not a free per-call tweak: give the same source two different sizes and
  /// they occupy two separate cache entries, which is what keeps a queue
  /// thumbnail from poisoning the 1280px hero. Sizes are clamped to the
  /// source's intrinsic dimensions and never upscale, so asking for more than
  /// the url provides is safe.
  ///
  /// Left null everywhere the image is drawn large, so that path decodes
  /// exactly as it did before.
  final int? cacheWidth;

  /// Physical pixel height to decode at. See [cacheWidth].
  final int? cacheHeight;

  /// How the bitmap is filtered when it is not drawn at its native size.
  ///
  /// The hero artwork is drawn at up to 320dp - around 960 physical pixels on a
  /// 3x screen - so a 480px-wide tier is being upscaled, and the default
  /// [FilterQuality.medium] is visibly soft doing it. [FilterQuality.high] costs
  /// a little more to composite and is worth it for the one large image in the
  /// app; it is exposed per call site rather than defaulted here, so a 36px queue
  /// thumbnail does not pay for it.
  final FilterQuality? filterQuality;

  /// Whether to ask the source for a larger download of the same image first.
  ///
  /// A catalogue url advertises at most 544px, which is not enough for a
  /// 320dp artwork and is far more than a 36dp queue row needs. Default off;
  /// set it only where the image is drawn large enough to show the difference.
  final bool upscale;

  /// Shown when every candidate fails.
  final Widget? fallback;

  /// How a url becomes something to paint.
  ///
  /// Defaults to a plain network fetch. It is a seam rather than a test hook:
  /// the candidate list is a list of *urls*, and anything that can load a url
  /// can sit behind this - a disk cache being the obvious next one.
  final ImageProvider Function(String url)? providerFor;

  @override
  State<ResilientArtwork> createState() => _ResilientArtworkState();
}

class _ResilientArtworkState extends State<ResilientArtwork> {
  /// How far down the candidate list we have got, or null while nothing has
  /// been tried yet.
  ///
  /// An index rather than a list, because [ArtworkSource.candidates] is
  /// deterministic for a url: recomputing it on each failure would be the same
  /// list, and remembering where we are is all that is needed.
  int? _candidate;

  @override
  void didUpdateWidget(ResilientArtwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A new track must start from the top of its own list, or it would inherit
    // the previous track's failures and skip straight past the tier that works.
    if (oldWidget.url != widget.url) _candidate = null;
  }

  @override
  Widget build(BuildContext context) {
    final candidates = ArtworkSource.candidates(
      widget.url,
      upscale: widget.upscale,
    );
    if (candidates.isEmpty) return widget.fallback ?? const SizedBox.shrink();

    final index = (_candidate ?? 0).clamp(0, candidates.length - 1);
    // Keyed by the candidate index so each attempt is a genuinely new [Image]
    // rather than a same-key element whose `errorBuilder` has already run - the
    // step-down would otherwise have nothing left to re-trigger it.
    return Image(
      key: ValueKey<int>(index),
      // Wrapped here rather than left to the `Image` constructor because the
      // general `Image({required image})` has no `cacheWidth` - only
      // Image.network/file/asset/memory do - and this widget resolves its own
      // provider through `providerFor`, which none of them can express.
      //
      // `resizeIfNeeded` is a no-op when both are null, so a caller that wants
      // no downscale keeps the bare provider and the image cache keys it
      // exactly as it did before.
      image: ResizeImage.resizeIfNeeded(
        widget.cacheWidth,
        widget.cacheHeight,
        widget.providerFor?.call(candidates[index]) ??
            NetworkImage(candidates[index]),
      ),
      width: widget.width,
      height: widget.height,
      fit: widget.fit,
      filterQuality: widget.filterQuality ?? FilterQuality.medium,
      // A step down is invisible: the next tier is the same picture, smaller.
      // Only the last attempt gets to say "there is no artwork here".
      errorBuilder: (context, _, _) {
        if (index < candidates.length - 1) {
          // Deferred to the next frame rather than done inline: setting state
          // during build would schedule a rebuild of this very widget.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            // `(_candidate ?? 0)`, not `_candidate`: the first attempt never set
            // the field, so comparing a null against index 0 would fail and
            // leave the very first 404 with nowhere to step down to.
            if ((_candidate ?? 0) == index) {
              setState(() => _candidate = index + 1);
            }
          });
          return const SizedBox.shrink();
        }
        return widget.fallback ?? const SizedBox.shrink();
      },
    );
  }
}
