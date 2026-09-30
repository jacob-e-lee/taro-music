import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:taro_music/core/artwork/artwork_source.dart';
import 'package:taro_music/core/artwork/resilient_artwork.dart';

/// A real-shaped YouTube Music catalogue url: the size is a query parameter,
/// and the API only ever advertises 544 for it.
const String _catalogueUrl =
    'https://lh3.googleusercontent.com/ABt3xk0aH6b0H3=Rr3eZQKM9VxE5jkk1y3Q'
    '=w544-h544-l90-rj';
void main() {
  group('ArtworkSource.candidates', () {
    test('a low tier is extended upward to the best one', () {
      expect(
        ArtworkSource.candidates('https://i.ytimg.com/vi/abc/hqdefault.jpg'),
        <String>[
          'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
          'https://i.ytimg.com/vi/abc/sddefault.jpg',
          'https://i.ytimg.com/vi/abc/hqdefault.jpg',
        ],
      );
    });

    test('mqdefault is upgraded, not left as the best', () {
      // Piped hands these out, and mqdefault is only 320x180 - which is what
      // made the player's artwork look soft.
      final candidates = ArtworkSource.candidates(
        'https://i.ytimg.com/vi/abc/mqdefault.jpg',
      );
      expect(candidates.first, contains('maxresdefault'));
    });

    test('bare default.jpg is upgraded', () {
      expect(
        ArtworkSource.candidates('https://i.ytimg.com/vi/abc/default.jpg')
            .first,
        'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
      );
    });

    test('the best tier is tried first and steps down from there', () {
      expect(
        ArtworkSource.candidates(
          'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
        ),
        <String>[
          'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
          'https://i.ytimg.com/vi/abc/sddefault.jpg',
          'https://i.ytimg.com/vi/abc/hqdefault.jpg',
        ],
      );
    });

    test('a mid tier is still offered the better ones first', () {
      // Deliberately the same list for every recognised tier: the whole point
      // is to try to *improve* on what the source handed us, so anchoring the
      // list at sddefault would leave a caller that picked it stuck on it.
      expect(
        ArtworkSource.candidates('https://i.ytimg.com/vi/abc/sddefault.jpg'),
        ArtworkSource.candidates(
          'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
        ),
      );
    });

    test('upscale off by default leaves a catalogue url at its given size', () {
      // The search page and the queue both draw this at 36-52dp, where a 1280px
      // download is 5x the bandwidth for pixels nobody ever sees.
      expect(ArtworkSource.candidates(_catalogueUrl), <String>[_catalogueUrl]);
    });

    test('upscale asks the catalogue for the same asset at 1280', () {
      expect(ArtworkSource.candidates(_catalogueUrl, upscale: true), <String>[
        _catalogueUrl.replaceFirst('=w544-h544', '=w1280-h1280'),
        _catalogueUrl,
      ]);
    });

    test('the original url is kept as the step down after an upscale', () {
      // A larger request is not honoured for every asset. When it 400s, the
      // answer has to be the image we already had, not a blank box.
      final candidates = ArtworkSource.candidates(_catalogueUrl, upscale: true);
      expect(candidates.last, _catalogueUrl);
    });

    test('upscaling keeps the trailing l90 and rj flags', () {
      // These are not sizes. `rj` in particular asks the CDN not to recompress
      // to JPEG; dropping it would change the image, not just its resolution.
      expect(
        ArtworkSource.candidates(_catalogueUrl, upscale: true).first,
        endsWith('-l90-rj'),
      );
    });

    test('an upscaled catalogue url differs only in the size parameter', () {
      final big = ArtworkSource.candidates(_catalogueUrl, upscale: true).first;
      expect(
        big.split('=').first,
        _catalogueUrl.split('=').first,
        reason: 'the asset id must be preserved exactly',
      );
    });

    test('upscale does nothing to a tiered url', () {
      // The tier logic already starts at the best tier; there is no size
      // parameter to rewrite and inventing one would produce a broken url.
      final plain = ArtworkSource.candidates(
        'https://i.ytimg.com/vi/abc/hqdefault.jpg',
      );
      expect(
        ArtworkSource.candidates(
          'https://i.ytimg.com/vi/abc/hqdefault.jpg',
          upscale: true,
        ),
        plain,
      );
    });

    test('upscale does nothing to a Piped url with no size parameter', () {
      const url = 'https://pipedapi.example/stream/abc/cover';
      expect(ArtworkSource.candidates(url, upscale: true), <String>[url]);
    });

    test('a size with no -h is not rewritten', () {
      // Only the full `=w544-h544` form is recognised, which is what the
      // catalogue emits. Guessing at other spellings risks rewriting a flag.
      const url = 'https://lh3.googleusercontent.com/xyz=w544-l90-rj';
      expect(ArtworkSource.candidates(url, upscale: true), <String>[url]);
    });
    test('a non-YouTube url passes through untouched', () {
      // A catalogue (lh3) url has no size tiers to move between, so inventing
      // some would be worse than using what we were given.
      expect(
        ArtworkSource.candidates('https://lh3.googleusercontent.com/xyz=w544'),
        <String>['https://lh3.googleusercontent.com/xyz=w544'],
      );
    });

    test('a bare hash thumbnail is left alone', () {
      expect(
        ArtworkSource.candidates('https://i.ytimg.com/vi/abc/0.jpg'),
        <String>['https://i.ytimg.com/vi/abc/0.jpg'],
      );
    });

    test('null and empty give nothing to try', () {
      expect(ArtworkSource.candidates(null), isEmpty);
      expect(ArtworkSource.candidates(''), isEmpty);
    });

    test('the host and id are preserved exactly', () {
      for (final host in <String>['i.ytimg.com', 'img.youtube.com']) {
        for (final name in <String>[
          'maxresdefault',
          'sddefault',
          'hqdefault',
          'mqdefault',
          'default',
        ]) {
          final candidates = ArtworkSource.candidates(
            'https://$host/vi/dQw4w9WgXcQ/$name.jpg',
          );
          expect(
            candidates,
            everyElement(startsWith('https://$host/vi/dQw4w9WgXcQ/')),
            reason: '$host/$name',
          );
        }
      }
    });
  });

  group('ResilientArtwork', () {
    /// Records every url asked for, and fails the ones named in [missing].
    ///
    /// Standing in for the network at [ResilientArtwork.providerFor] rather
    /// than faking an `HttpClient`, so the test drives the tier walk directly
    /// instead of going through a real image decode.
    Future<List<String>> harness(
      WidgetTester tester, {
      required Set<String> missing,
      String url = 'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
    }) async {
      final requested = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(
            url: url,
            fallback: const Text('FALLBACK'),
            providerFor: (url) {
              requested.add(url);
              // Matched on the tier name, which is what the tests name, rather
              // than on the whole url.
              return _FakeImageProvider(
                url,
                fail: missing.any((tier) => url.endsWith('/$tier.jpg')),
              );
            },
          ),
        ),
      );
      return requested;
    }

    /// Runs the post-frame callbacks that drive the step-down, and settles.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    testWidgets('a missing top tier falls through to the next', (
      WidgetTester tester,
    ) async {
      // `/maxresdefault.jpg` 404s for roughly a quarter of real videos, so
      // this is the common case rather than an edge one.
      final requested = await harness(
        tester,
        missing: <String>{'maxresdefault'},
      );
      await settle(tester);

      expect(requested.first, contains('maxresdefault'));
      expect(requested, contains('https://i.ytimg.com/vi/abc/sddefault.jpg'));
      expect(find.text('FALLBACK'), findsNothing);
    });

    testWidgets('the best tier is used when it is there', (
      WidgetTester tester,
    ) async {
      final requested = await harness(tester, missing: <String>{});
      await settle(tester);

      expect(requested, <String>[
        'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
      ]);
    });

    testWidgets('the fallback appears only after every tier has failed', (
      WidgetTester tester,
    ) async {
      await harness(
        tester,
        missing: <String>{'maxresdefault', 'sddefault', 'hqdefault'},
      );
      await settle(tester);

      expect(find.text('FALLBACK'), findsOneWidget);
    });

    testWidgets('shows the fallback immediately when there is no url', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(url: null, fallback: const Text('FALLBACK')),
        ),
      );
      expect(find.text('FALLBACK'), findsOneWidget);
    });

    testWidgets('a non-YouTube url is used exactly as given', (
      WidgetTester tester,
    ) async {
      final requested = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(
            url: 'https://lh3.googleusercontent.com/xyz=w544',
            fallback: const Text('FALLBACK'),
            providerFor: (url) {
              requested.add(url);
              return _FakeImageProvider(url);
            },
          ),
        ),
      );
      await settle(tester);

      // There is no higher tier to try, so inventing one would only produce a
      // request that cannot work.
      expect(requested, <String>['https://lh3.googleusercontent.com/xyz=w544']);
    });

    testWidgets('upscale requests the large catalogue url first', (
      WidgetTester tester,
    ) async {
      final requested = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(
            url: _catalogueUrl,
            width: 320,
            height: 320,
            upscale: true,
            fallback: const Text('FALLBACK'),
            providerFor: (url) {
              requested.add(url);
              return _FakeImageProvider(url);
            },
          ),
        ),
      );
      await settle(tester);

      // This is the behaviour the mini-player depends on: one request, at the
      // size the expanded player will need, so opening it is instant.
      expect(requested.first, contains('=w1280-h1280'));
    });

    testWidgets('a small caller does not upscale', (WidgetTester tester) async {
      // The queue row and the search tile draw this at 36-52dp. Requesting
      // 1280px there would spend ~5x the bandwidth on invisible detail.
      final requested = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(
            url: _catalogueUrl,
            width: 36,
            height: 36,
            providerFor: (url) {
              requested.add(url);
              return _FakeImageProvider(url);
            },
          ),
        ),
      );
      await settle(tester);

      expect(requested, <String>[_catalogueUrl]);
    });

    testWidgets('a failed upscale steps down to the original url', (
      WidgetTester tester,
    ) async {
      // The larger request is not honoured for every asset, so the original
      // has to still be in the chain.
      final requested = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(
            url: _catalogueUrl,
            upscale: true,
            providerFor: (url) {
              requested.add(url);
              return _FakeImageProvider(url, fail: url.contains('w1280'));
            },
          ),
        ),
      );
      await settle(tester);

      expect(requested, <String>[
        _catalogueUrl.replaceFirst('=w544-h544', '=w1280-h1280'),
        _catalogueUrl,
      ]);
    });
    testWidgets('changing url restarts the chain from the top', (
      WidgetTester tester,
    ) async {
      final requested = await harness(
        tester,
        missing: <String>{'maxresdefault'},
      );
      await settle(tester);
      expect(requested.length, greaterThan(1));

      // A new track must not inherit the previous one's exhausted chain, or it
      // would jump straight to the fallback even though its top tier is fine.
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(
            url: 'https://i.ytimg.com/vi/other/maxresdefault.jpg',
            fallback: const Text('FALLBACK'),
            providerFor: (url) {
              requested.add(url);
              return _FakeImageProvider(url);
            },
          ),
        ),
      );
      await settle(tester);

      expect(requested.last, 'https://i.ytimg.com/vi/other/maxresdefault.jpg');
    });
  });

  // Decode size.
  //
  // These assert on the provider's own type and dimensions rather than on the
  // `Image` widget, which has no `cacheWidth` field to read. The provider is
  // reachable here precisely *because* this widget wraps `providerFor`'s result
  // in a `ResizeImage` itself - so the fake does flow through the real wrap
  // rather than bypassing it, and these are not vacuous.
  group('ResilientArtwork decode size', () {
    ImageProvider<Object> providerIn(WidgetTester tester) =>
        tester.widget<Image>(find.byType(Image)).image;

    ResizeImage resizedIn(WidgetTester tester) =>
        providerIn(tester) as ResizeImage;

    /// Local copy of the harness's settle, which is scoped to the other group.
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 40));
      }
    }

    testWidgets('a caller that asks for a size decodes at that size', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ResilientArtwork(
            url: _catalogueUrl,
            width: 36,
            height: 36,
            cacheWidth: 108,
            cacheHeight: 108,
            providerFor: _fakeProvider,
          ),
        ),
      );

      expect(resizedIn(tester).width, 108);
      expect(resizedIn(tester).height, 108);
    });

    testWidgets('no size means no ResizeImage at all', (
      WidgetTester tester,
    ) async {
      // The hero leaves these null and must keep its bare provider: a default
      // that quietly downsized the 1280px artwork would be a visible bug, and
      // this is the guard against it.
      await tester.pumpWidget(
        const MaterialApp(
          home: ResilientArtwork(
            url: _catalogueUrl,
            width: 320,
            height: 320,
            upscale: true,
            providerFor: _fakeProvider,
          ),
        ),
      );

      // The bare provider, not a ResizeImage with null dimensions.
      expect(providerIn(tester), isNot(isA<ResizeImage>()));
    });

    testWidgets('a small and a large caller cannot share a cache entry', (
      WidgetTester tester,
    ) async {
      // The safety property the whole change rests on. Both callers ask for the
      // same url at different sizes; if they keyed alike, whichever loaded first
      // would hand the other a bitmap decoded at the wrong size.
      //
      // Compared through `obtainKey`, the same thing the ImageCache does, since
      // `ResizeImageKey`'s constructor is private and cannot be built here.
      Future<Object> keyFor(int size) async {
        final provider = ResizeImage(
          _FakeImageProvider(_catalogueUrl),
          width: size,
          height: size,
        );
        return provider.obtainKey(ImageConfiguration.empty);
      }

      expect(await keyFor(108), isNot(await keyFor(1280)));
      // And the same size twice *does* collide, so this is a real key comparison
      // rather than one that returns unequal for everything.
      expect(await keyFor(108), await keyFor(108));
    });

    testWidgets('the decode size survives a step down to the next tier', (
      WidgetTester tester,
    ) async {
      // The step-down rebuilds `Image` from scratch. If the replacement were
      // built without the size, every failed tier would quietly return to a
      // full-size decode - invisible until a row with a broken top tier got
      // slow.
      await tester.pumpWidget(
        MaterialApp(
          home: ResilientArtwork(
            url: 'https://i.ytimg.com/vi/abc/maxresdefault.jpg',
            cacheWidth: 108,
            cacheHeight: 108,
            providerFor: (url) => _FakeImageProvider(
              url,
              fail: url.endsWith('/maxresdefault.jpg'),
            ),
          ),
        ),
      );
      await settle(tester);

      expect(find.byType(Image), findsOneWidget);
      expect(resizedIn(tester).width, 108);
      expect(resizedIn(tester).height, 108);
    });
  });
}

/// A [ResilientArtwork.providerFor] that never touches the network.
ImageProvider<Object> _fakeProvider(String url) => _FakeImageProvider(url);

/// An [ImageProvider] that either resolves or throws, and never touches the
/// network.
///
/// Real bytes so a "successful" load has something to decode, and a
/// [StateError] otherwise so the widget's `errorBuilder` is reached - which is
/// the branch the whole tier walk depends on.
class _FakeImageProvider extends ImageProvider<_FakeImageProvider> {
  _FakeImageProvider(this.url, {this.fail = false});

  final String url;
  final bool fail;

  @override
  Future<_FakeImageProvider> obtainKey(ImageConfiguration _) =>
      SynchronousFuture<_FakeImageProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    _FakeImageProvider key,
    ImageDecoderCallback decode,
  ) {
    // Decoded by Flutter's own image machinery, so a "successful" load is a real
    // decode rather than a stub. The failure is a rejected future, which is
    // what a 404 looks like to [Image] - and therefore the branch the whole tier
    // walk depends on.
    return OneFrameImageStreamCompleter(
      fail
          ? Future<ImageInfo>.error(StateError('404 for $url'))
          : _decode(_onePixelPng, key, decode),
    );
  }

  Future<ImageInfo> _decode(
    List<int> bytes,
    _FakeImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      Uint8List.fromList(bytes),
    );
    final codec = await decode(
      buffer,
      // No resize: the point of this provider is only to succeed or fail, and
      // the 1x1 image has nothing to scale.
      getTargetSize: (_, _) => const ui.TargetImageSize(width: 1, height: 1),
    );
    final frame = await codec.getNextFrame();
    return ImageInfo(image: frame.image, scale: 1, debugLabel: key.url);
  }

  @override
  bool operator ==(Object other) =>
      other is _FakeImageProvider && other.url == url && other.fail == fail;

  @override
  int get hashCode => Object.hash(url, fail);
}

/// A 1x1 JPEG, so a successful decode has real bytes to work with.
/// A 1x1 PNG, so a successful decode has real bytes to work with.
///
/// Chosen over a JPEG because a hand-written JPEG is easy to get subtly
/// wrong, and a corrupt one fails as a *decode* error - indistinguishable from a
/// 404 to this widget, so a broken fixture would make every tier look missing.
const List<int> _onePixelPng = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x00,
  0x00,
  0x00,
  0x00,
  0x3A,
  0x7E,
  0x9B,
  0x55,
  0x00,
  0x00,
  0x00,
  0x0A,
  0x49,
  0x44,
  0x41,
  0x54,
  0x78,
  0x9C,
  0x63,
  0x00,
  0x01,
  0x00,
  0x00,
  0x05,
  0x00,
  0x01,
  0x0D,
  0x0A,
  0x2D,
  0xB4,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
