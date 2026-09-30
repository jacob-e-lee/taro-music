import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:taro_music/core/artwork/artwork_source.dart';

/// Checks the *real* fix, over the network.
///
/// A fake image provider cannot catch this class of bug: it happily serves a
/// 544px "success" for a request that in production returned a 544px image. The
/// original tests all passed while the player's artwork was visibly soft,
/// because every one of them asserted on the url rather than on what came
/// back. So this asserts on the bytes.
///
/// Skipped unless `TARO_NETWORK_TESTS=1`, so an offline or CI run without
/// network access still passes. Run with:
///
///     $env:TARO_NETWORK_TESTS=1; flutter test test/artwork_network_test.dart
void main() {
  final enabled = Platform.environment['TARO_NETWORK_TESTS'] == '1';
  final skip = enabled ? null : 'set TARO_NETWORK_TESTS=1 to run';

  // Taken from the environment rather than hardcoded. A YouTube Music
  // catalogue url embeds a signed-looking asset id that this repo has no
  // business carrying, and inventing one would just 404 and make the test look
  // like the fix is broken. To run it, paste a real one from a search result:
  //
  //     $env:TARO_NETWORK_URL='https://lh3.googleusercontent.com/....=w544-h544-l90-rj'
  //
  final assetId = Platform.environment['TARO_NETWORK_URL'] ?? '';
  final urlSkip = assetId.isEmpty
      ? 'set TARO_NETWORK_URL to a real catalogue url'
      : skip;
  '=w544-h544-l90-rj';

  test('the size parameter is what the image resolution follows', () async {
    final small = ArtworkSource.candidates(assetId).single;
    final large = ArtworkSource.candidates(assetId, upscale: true).first;

    final smallImage = await _fetch(small);
    final largeImage = await _fetch(large);

    // ignore: avoid_print
    print(
      '544  -> ${smallImage.width}x${smallImage.height} '
      '(${(await _sizeOf(small)) ~/ 1024}KB)',
    );
    // ignore: avoid_print
    print(
      '1280 -> ${largeImage.width}x${largeImage.height} '
      '(${(await _sizeOf(large)) ~/ 1024}KB)',
    );

    expect(
      largeImage.width,
      greaterThanOrEqualTo(1024),
      reason: 'the upscaled url must actually return a larger image',
    );
  }, skip: urlSkip);
}

Future<_Image> _fetch(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != 200) {
      throw HttpException('HTTP ${response.statusCode} for $url');
    }
    final chunks = await response.toList();
    return _Image(Uint8List.fromList(chunks.expand((c) => c).toList()));
  } finally {
    client.close();
  }
}

Future<int> _sizeOf(String url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    return response.contentLength;
  } finally {
    client.close();
  }
}

/// Width and height read out of the JPEG's SOF marker.
///
/// Deliberately not `instantiateImageCodec`: that needs the Flutter engine,
/// and the point here is to compare two *downloads* against each other, which a
/// pure-Dart header read is enough for.
class _Image {
  _Image(Uint8List bytes) {
    var i = 2; // skip SOI
    while (i + 9 < bytes.length) {
      if (bytes[i] != 0xFF) {
        i++;
        continue;
      }
      final marker = bytes[i + 1];
      // SOF0-SOF15, skipping the non-frame markers in that range.
      final isSof =
          marker >= 0xC0 &&
          marker <= 0xCF &&
          marker != 0xC4 &&
          marker != 0xC8 &&
          marker != 0xCC;
      if (isSof) {
        height = (bytes[i + 5] << 8) | bytes[i + 6];
        width = (bytes[i + 7] << 8) | bytes[i + 8];
        return;
      }
      final length = (bytes[i + 2] << 8) | bytes[i + 3];
      if (length <= 0) return;
      i += 2 + length;
    }
  }

  int width = 0;
  int height = 0;
}
