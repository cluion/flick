enum PreviewSortField {
  addedOrder,
  originalName,
  proposedName,
  extension,
  size,
  modifiedTime,
  path,
}

extension PreviewSortFieldLabel on PreviewSortField {
  String get label => switch (this) {
    PreviewSortField.addedOrder => '加入順序',
    PreviewSortField.originalName => '原始檔名',
    PreviewSortField.proposedName => '新檔名',
    PreviewSortField.extension => '副檔名',
    PreviewSortField.size => '檔案大小',
    PreviewSortField.modifiedTime => '修改時間',
    PreviewSortField.path => '完整路徑',
  };
}

class PreviewListRecord {
  const PreviewListRecord({
    required this.sourceIndex,
    required this.path,
    required this.originalName,
    required this.proposedName,
    required this.size,
    required this.modifiedAt,
  });

  final int sourceIndex;
  final String path;
  final String originalName;
  final String proposedName;
  final int size;
  final int modifiedAt;

  String get extension {
    final dot = originalName.lastIndexOf('.');
    return dot > 0 && dot < originalName.length - 1
        ? originalName.substring(dot + 1)
        : '';
  }

  bool matches(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return true;
    return originalName.toLowerCase().contains(normalized) ||
        proposedName.toLowerCase().contains(normalized) ||
        path.toLowerCase().contains(normalized) ||
        extension.toLowerCase().contains(normalized);
  }
}

List<int> visiblePreviewIndices({
  required List<PreviewListRecord> records,
  required String query,
  required PreviewSortField sortField,
  required bool ascending,
}) {
  final visible = records.where((record) => record.matches(query)).toList();
  visible.sort((left, right) {
    final compared = _compareRecords(left, right, sortField);
    if (compared != 0) return ascending ? compared : -compared;
    return left.sourceIndex.compareTo(right.sourceIndex);
  });
  return List.unmodifiable(
    visible.map((record) => record.sourceIndex).toList(growable: false),
  );
}

int _compareRecords(
  PreviewListRecord left,
  PreviewListRecord right,
  PreviewSortField field,
) {
  return switch (field) {
    PreviewSortField.addedOrder => left.sourceIndex.compareTo(
      right.sourceIndex,
    ),
    PreviewSortField.originalName => _compareText(
      left.originalName,
      right.originalName,
    ),
    PreviewSortField.proposedName => _compareText(
      left.proposedName,
      right.proposedName,
    ),
    PreviewSortField.extension => _compareText(left.extension, right.extension),
    PreviewSortField.size => left.size.compareTo(right.size),
    PreviewSortField.modifiedTime => left.modifiedAt.compareTo(
      right.modifiedAt,
    ),
    PreviewSortField.path => _compareText(left.path, right.path),
  };
}

int _compareText(String left, String right) {
  return left.toLowerCase().compareTo(right.toLowerCase());
}
