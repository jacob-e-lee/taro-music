import 'package:flutter/foundation.dart';

/// Where a track's artwork comes from, and how to get the best version of it.
///
/// YouTube serves one image per size tier, and the top tier is **not
/// guaranteed** to be there: `maxresdefault.jpg` (1280x720) only exists for
/// videos that were ever uploaded in HD. How often that actually happens is
/// unmeasured here - do not cite a figure for it. The point is only that asking
/// for the biggest name is not guaranteed to succeed, and when it doesn't the
/// player would show its placeholder where artwork would have done.
///
/// The fix is a candidate list rather than a single URL: try the best tier
/// first and step down on failure. [ArtworkSource.candidates] produces that
/// list, and [ResilientArtwork] (in the presentation layer) walks it.
///
/// Two kinds of url arrive here, and they need opposite treatment:
///
///  * `i.ytimg.com/vi/<id>/<tier>.jpg` - the size tier is in the *path*, so a
///    better one is derivable by substitution.
///  * `*.googleusercontent.com/<id>=w544-h544-l90-rj` - the YouTube Music
///    catalogue, where the size is a **query parameter**.
///
/// The second one is the reason [candidates] takes an `upscale` flag. The
/// catalogue API only ever advertises thumbnails up to 544px, so a source
/// picking the "largest" of them is picking a 544px image - while the CDN will
/// serve the same asset at 1280 for the same id. Measured on one real track:
/// 544 returned 59KB, 1280 returned 324KB. That was the actual cause of soft
/// player artwork.
///
/// It is opt-in rather than default because the right size depends entirely on
/// how big the image will be *drawn*, which only the call site knows: a 320dp
/// player artwork wants those pixels, and a 52dp search tile would be paying
/// 5x the bandwidth for a file nobody ever sees at that resolution.
@immutable
class ArtworkSource {
  const ArtworkSource._();

  /// The candidate URLs for [url], best first, followed by any lower tiers
  /// that can be derived from it.
  ///
  /// When [upscale] is true, a catalogue url is asked for at a larger size
  /// first, with the original kept as the step-down candidate. Off by default;
  /// see the class doc for why.
  ///
  /// Returns a single-element list for anything not recognised as a YouTube
  /// thumbnail, so a Piped url passes straight through untouched.
  static List<String> candidates(String? url, {bool upscale = false}) {
    if (url == null || url.isEmpty) return const <String>[];

    if (_isTiered(url)) {
      // Always start from the best tier, whatever the source handed us. A url
      // naming `hqdefault` is exactly the case that made the player's artwork
      // look soft, so starting the list at that tier would reproduce the
      // problem; and a url naming `maxresdefault` simply never needs the tiers
      // above it anyway, so asking for the list from the top is free.
      return <String>[
        for (final name in _tiers)
          // The trailing tier is replaced, not appended to: the host and the
          // video id in front of it are exactly as they were.
          url.replaceFirst(_tierSuffixOf(url), '/$name.jpg'),
      ];
    }

    if (upscale) {
      final bigger = _biggerCatalogueUrl(url);
      if (bigger != null) {
        // The url we were given stays in the list as the step down. A larger
        // request is not guaranteed to be honoured for every asset, and when it
        // is not the answer should be the image we already have - not no image
        // at all.
        return <String>[bigger, url];
      }
    }
    return <String>[url];
  }

  /// The same catalogue asset asked for at [_upscaleDimensions], or null when
  /// [url] is not a catalogue url that names a size.
  ///
  /// Only the `=w544-h544` part is rewritten; the trailing flags are left
  /// alone because they are not sizes. `l90` asks for lossy and `rj` asks the
  /// CDN not to recompress to JPEG - dropping either would change the image
  /// rather than its resolution.
  static String? _biggerCatalogueUrl(String url) {
    if (!url.contains('googleusercontent.com')) return null;
    if (!_sizeParam.hasMatch(url)) return null;
    return url.replaceFirst(_sizeParam, '=$_upscaleDimensions');
  }

  /// The `=w544-h544` size parameter, and only that.
  ///
  /// Anchored on the leading `=` so a `-h544` or `-l90` appearing elsewhere in
  /// the query string can never be mistaken for the size being rewritten.
  /// Requiring both dimensions matches what the catalogue actually emits.
  static final RegExp _sizeParam = RegExp(r'=w\d+-h\d+');

  /// What [_biggerCatalogueUrl] asks for instead.
  ///
  /// 1280 rather than the undocumented `=s0`, which served a larger image
  /// (1400px) on the track this was measured against but is not a documented
  /// size and is likelier to be rejected. 1280 already covers the ~960 physical
  /// pixels that a 320dp artwork occupies on a 3x screen, so the larger
  /// original would buy nothing visible.
  static const String _upscaleDimensions = 'w1280-h1280';

  /// The `.../<tier>.jpg` tail of a YouTube thumbnail url.
  ///
  /// A plain string rather than a [RegExp] so `replaceFirst` can be used
  /// directly, and so the *actual* suffix from this url is what gets swapped -
  /// `mqdefault` and `default` are not the same length as `hqdefault`, and
  /// assuming one spelling would mangle the other.
  static String _tierSuffixOf(String url) {
    for (final name in _tierNames) {
      final suffix = '/$name.jpg';
      if (url.endsWith(suffix)) return suffix;
    }
    return '';
  }

  /// Every tier name worth recognising, including the two that are not in the
  /// list we request: a Piped result is typically `mqdefault` or `default`, and
  /// those are exactly the urls that need upgrading.
  static const List<String> _tierNames = <String>[
    'maxresdefault',
    'sddefault',
    'hqdefault',
    'mqdefault',
    'default',
  ];

  /// Whether [url] names a YouTube size tier at all, as opposed to being a
  /// catalogue url or a bare `<hash>.jpg` frame.
  static bool _isTiered(String url) => _tierSuffixOf(url).isNotEmpty;

  /// The YouTube thumbnail sizes requested, best first.
  ///
  /// `mqdefault` and `default` are recognised by [_tierNames] but deliberately
  /// not requested: they are the smallest, and a source that only offers them
  /// has nothing better to give.
  static const List<String> _tiers = <String>[
    'maxresdefault',
    'sddefault',
    'hqdefault',
  ];
}
