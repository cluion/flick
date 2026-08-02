import 'rename_rule.dart';

List<String> decodeRenameListFile({
  required String content,
  required bool csv,
}) {
  final normalized = content.startsWith('\uFEFF')
      ? content.substring(1)
      : content;
  if (!csv) return parseRenameListText(normalized);

  final rows = _parseCsvRows(normalized);
  while (rows.isNotEmpty && rows.last.every((cell) => cell.isEmpty)) {
    rows.removeLast();
  }
  if (rows.isEmpty) return const [];

  final headerIndex = rows.first.indexWhere(_isProposedNameHeader);
  final column = headerIndex >= 0
      ? headerIndex
      : rows.fold<int>(
              1,
              (width, row) => row.length > width ? row.length : width,
            ) -
            1;
  final start = headerIndex >= 0 ? 1 : 0;
  return List.unmodifiable([
    for (var index = start; index < rows.length; index++)
      column < rows[index].length ? rows[index][column] : '',
  ]);
}

String encodeRenameMappingCsv({
  required List<String> originalNames,
  required List<String> proposedNames,
}) {
  if (originalNames.length != proposedNames.length) {
    throw ArgumentError('Original and proposed name counts must match.');
  }
  final rows = <List<String>>[
    const ['originalName', 'proposedName'],
    for (var index = 0; index < originalNames.length; index++)
      [originalNames[index], proposedNames[index]],
  ];
  return '\uFEFF${rows.map((row) => row.map(_encodeCsvCell).join(',')).join('\r\n')}\r\n';
}

bool _isProposedNameHeader(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[\s_-]+'),
    '',
  );
  return const {
    'proposedname',
    'newname',
    'targetname',
    '新檔名',
  }.contains(normalized);
}

String _encodeCsvCell(String value) {
  if (!value.contains(RegExp(r'[,"\r\n]'))) return value;
  return '"${value.replaceAll('"', '""')}"';
}

List<List<String>> _parseCsvRows(String content) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;

  void finishField() {
    row.add(field.toString());
    field.clear();
  }

  void finishRow() {
    finishField();
    rows.add(row);
    row = <String>[];
  }

  for (var index = 0; index < content.length; index++) {
    final character = content[index];
    if (character == '"') {
      if (quoted && index + 1 < content.length && content[index + 1] == '"') {
        field.write('"');
        index++;
      } else {
        quoted = !quoted;
      }
      continue;
    }
    if (!quoted && character == ',') {
      finishField();
      continue;
    }
    if (!quoted && (character == '\n' || character == '\r')) {
      finishRow();
      if (character == '\r' &&
          index + 1 < content.length &&
          content[index + 1] == '\n') {
        index++;
      }
      continue;
    }
    field.write(character);
  }
  if (quoted) throw const FormatException('CSV contains an unclosed quote.');
  if (field.isNotEmpty || row.isNotEmpty) finishRow();
  return rows;
}
