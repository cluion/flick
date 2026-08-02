import 'package:flick/domain/rename_list_io.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('loads newline-separated TXT names', () {
    expect(
      decodeRenameListFile(content: '\uFEFFfirst\r\nsecond\r\n', csv: false),
      ['first', 'second'],
    );
  });

  test('loads proposed names from an exported CSV mapping', () {
    const content =
        'originalName,proposedName\r\n'
        'one.txt,"First, renamed.txt"\r\n'
        'two.txt,"Second ""quoted"".txt"\r\n';

    expect(decodeRenameListFile(content: content, csv: true), [
      'First, renamed.txt',
      'Second "quoted".txt',
    ]);
  });

  test('loads the last column when a CSV has no recognized header', () {
    expect(decodeRenameListFile(content: 'one,alpha\ntwo,beta\n', csv: true), [
      'alpha',
      'beta',
    ]);
  });

  test('exports a round-trippable CSV mapping', () {
    final csv = encodeRenameMappingCsv(
      originalNames: const ['one.txt', 'two.txt'],
      proposedNames: const ['First, renamed.txt', 'Second "quoted".txt'],
    );

    expect(csv, startsWith('\uFEFForiginalName,proposedName\r\n'));
    expect(decodeRenameListFile(content: csv, csv: true), [
      'First, renamed.txt',
      'Second "quoted".txt',
    ]);
  });

  test('rejects malformed quoted CSV', () {
    expect(
      () => decodeRenameListFile(content: '"unfinished', csv: true),
      throwsFormatException,
    );
  });
}
