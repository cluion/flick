import 'dart:convert';

const flickFileListFormat = 'flick-file-list';
const flickFileListSchemaVersion = 1;

class FlickFileListItem {
  const FlickFileListItem({
    required this.path,
    required this.included,
    this.overrideName,
  });

  final String path;
  final bool included;
  final String? overrideName;
}

class FlickFileList {
  const FlickFileList(this.items);

  final List<FlickFileListItem> items;
}

String encodeFlickFileList({
  required List<String> paths,
  required Set<String> excludedPaths,
  required Map<String, String> nameOverrides,
}) {
  final document = <String, Object>{
    'format': flickFileListFormat,
    'schemaVersion': flickFileListSchemaVersion,
    'items': [
      for (final path in paths)
        <String, Object>{
          'path': path,
          'included': !excludedPaths.contains(path),
          'overrideName': ?nameOverrides[path],
        },
    ],
  };
  return '${const JsonEncoder.withIndent('  ').convert(document)}\n';
}

FlickFileList decodeFlickFileList(String content) {
  final normalized = content.startsWith('\uFEFF')
      ? content.substring(1)
      : content;
  final Object? decoded = jsonDecode(normalized);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('檔案清單的最外層必須是 JSON 物件');
  }
  if (decoded['format'] != flickFileListFormat) {
    throw const FormatException('這不是 Flick 檔案清單');
  }

  final schemaVersion = decoded['schemaVersion'];
  if (schemaVersion is! int) {
    throw const FormatException('檔案清單缺少有效的 schemaVersion');
  }
  if (schemaVersion > flickFileListSchemaVersion) {
    throw FormatException('此檔案清單需要較新的 Flick（schema $schemaVersion）');
  }
  if (schemaVersion != flickFileListSchemaVersion) {
    throw FormatException('不支援的檔案清單版本：$schemaVersion');
  }

  final rawItems = decoded['items'];
  if (rawItems is! List<Object?>) {
    throw const FormatException('檔案清單缺少 items 陣列');
  }

  final seenPaths = <String>{};
  final items = <FlickFileListItem>[];
  for (var index = 0; index < rawItems.length; index++) {
    final rawItem = rawItems[index];
    if (rawItem is! Map<String, dynamic>) {
      throw FormatException('第 ${index + 1} 個清單項目格式不正確');
    }
    final path = rawItem['path'];
    if (path is! String || path.isEmpty) {
      throw FormatException('第 ${index + 1} 個清單項目缺少檔案路徑');
    }
    if (!seenPaths.add(path)) {
      throw FormatException('檔案清單包含重複路徑：$path');
    }

    final included = rawItem['included'] ?? true;
    if (included is! bool) {
      throw FormatException('第 ${index + 1} 個清單項目的 included 必須是布林值');
    }
    final overrideName = rawItem['overrideName'];
    if (overrideName != null &&
        (overrideName is! String || overrideName.isEmpty)) {
      throw FormatException('第 ${index + 1} 個清單項目的手動檔名不正確');
    }

    items.add(
      FlickFileListItem(
        path: path,
        included: included,
        overrideName: overrideName as String?,
      ),
    );
  }
  return FlickFileList(List.unmodifiable(items));
}
