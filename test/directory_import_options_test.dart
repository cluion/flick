import 'package:flick/domain/directory_import_options.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses and deduplicates directory file patterns', () {
    expect(parseDirectoryPatterns(' *.jpg;*.PNG, *.jpg\n*.gif '), [
      '*.jpg',
      '*.PNG',
      '*.gif',
    ]);
  });

  test('blank directory file patterns include every file', () {
    expect(parseDirectoryPatterns('  ; , \n '), isEmpty);
  });
}
