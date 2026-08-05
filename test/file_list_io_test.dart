import 'dart:convert';

import 'package:flick/domain/file_list_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('round-trips order, inclusion, and manual names', () {
    final encoded = encodeFlickFileList(
      paths: const ['/Users/example/圖片 one.jpg', r'C:\Media\clip.mp4'],
      excludedPaths: const {r'C:\Media\clip.mp4'},
      nameOverrides: const {'/Users/example/圖片 one.jpg': 'cover.jpg'},
    );

    final decoded = decodeFlickFileList(encoded);

    expect(decoded.items.map((item) => item.path), [
      '/Users/example/圖片 one.jpg',
      r'C:\Media\clip.mp4',
    ]);
    expect(decoded.items.map((item) => item.included), [true, false]);
    expect(decoded.items.map((item) => item.overrideName), ['cover.jpg', null]);
  });

  test('accepts a BOM and defaults missing included to true', () {
    final content = jsonEncode({
      'format': flickFileListFormat,
      'schemaVersion': flickFileListSchemaVersion,
      'items': [
        {'path': '/tmp/example.txt'},
      ],
    });

    final decoded = decodeFlickFileList('\uFEFF$content');

    expect(decoded.items.single.included, isTrue);
  });

  test('rejects lists from a newer schema', () {
    final content = jsonEncode({
      'format': flickFileListFormat,
      'schemaVersion': flickFileListSchemaVersion + 1,
      'items': <Object>[],
    });

    expect(
      () => decodeFlickFileList(content),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('較新的 Flick'),
        ),
      ),
    );
  });

  test('rejects duplicate paths', () {
    final content = jsonEncode({
      'format': flickFileListFormat,
      'schemaVersion': flickFileListSchemaVersion,
      'items': [
        {'path': '/tmp/example.txt'},
        {'path': '/tmp/example.txt'},
      ],
    });

    expect(() => decodeFlickFileList(content), throwsFormatException);
  });
}
