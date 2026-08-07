import 'dart:io';

class VirtualOrganizationFolder {
  const VirtualOrganizationFolder({required this.id, required this.name});

  final String id;
  final String name;

  VirtualOrganizationFolder copyWith({String? name}) {
    return VirtualOrganizationFolder(id: id, name: name ?? this.name);
  }
}

class OrganizationWorkspaceItem {
  const OrganizationWorkspaceItem({
    required this.id,
    required this.sourcePath,
    this.destinationFolderId,
  });

  final String id;
  final String sourcePath;
  final String? destinationFolderId;

  OrganizationWorkspaceItem copyWith({
    String? destinationFolderId,
    bool clearDestination = false,
  }) {
    return OrganizationWorkspaceItem(
      id: id,
      sourcePath: sourcePath,
      destinationFolderId: clearDestination
          ? null
          : destinationFolderId ?? this.destinationFolderId,
    );
  }
}

class OrganizationWorkspaceDraft {
  const OrganizationWorkspaceDraft({
    this.folders = const [],
    this.items = const [],
  });

  final List<VirtualOrganizationFolder> folders;
  final List<OrganizationWorkspaceItem> items;

  OrganizationWorkspaceDraft reconcilePaths(
    Iterable<String> paths, {
    required String Function() nextItemId,
  }) {
    final existing = {for (final item in items) item.sourcePath: item};
    final seen = <String>{};
    final reconciled = <OrganizationWorkspaceItem>[];
    for (final path in paths) {
      if (path.isEmpty || !seen.add(path)) continue;
      reconciled.add(
        existing[path] ??
            OrganizationWorkspaceItem(id: nextItemId(), sourcePath: path),
      );
    }
    return OrganizationWorkspaceDraft(
      folders: folders,
      items: List.unmodifiable(reconciled),
    );
  }

  OrganizationWorkspaceDraft addFolder(VirtualOrganizationFolder folder) {
    if (folders.any((candidate) => candidate.id == folder.id)) {
      throw ArgumentError.value(folder.id, 'folder.id', 'must be unique');
    }
    return OrganizationWorkspaceDraft(
      folders: List.unmodifiable([...folders, folder]),
      items: items,
    );
  }

  OrganizationWorkspaceDraft renameFolder(String folderId, String name) {
    if (!folders.any((folder) => folder.id == folderId)) {
      throw ArgumentError.value(folderId, 'folderId', 'does not exist');
    }
    return OrganizationWorkspaceDraft(
      folders: List.unmodifiable([
        for (final folder in folders)
          if (folder.id == folderId) folder.copyWith(name: name) else folder,
      ]),
      items: items,
    );
  }

  OrganizationWorkspaceDraft assignItem(
    String itemId,
    String? destinationFolderId,
  ) {
    if (destinationFolderId != null &&
        !folders.any((folder) => folder.id == destinationFolderId)) {
      throw ArgumentError.value(
        destinationFolderId,
        'destinationFolderId',
        'does not exist',
      );
    }
    if (!items.any((item) => item.id == itemId)) {
      throw ArgumentError.value(itemId, 'itemId', 'does not exist');
    }
    return OrganizationWorkspaceDraft(
      folders: folders,
      items: List.unmodifiable([
        for (final item in items)
          if (item.id == itemId)
            item.copyWith(
              destinationFolderId: destinationFolderId,
              clearDestination: destinationFolderId == null,
            )
          else
            item,
      ]),
    );
  }

  VirtualOrganizationFolder? folderById(String? folderId) {
    if (folderId == null) return null;
    for (final folder in folders) {
      if (folder.id == folderId) return folder;
    }
    return null;
  }

  List<OrganizationWorkspaceItem> itemsInFolder(String? folderId) {
    return items
        .where((item) => item.destinationFolderId == folderId)
        .toList(growable: false);
  }
}

String organizationFileName(String path) {
  final segments = path
      .split(RegExp(r'[/\\]'))
      .where((segment) => segment.isNotEmpty);
  return segments.isEmpty ? path : segments.last;
}

String? inferOrganizationRoot(Iterable<String> paths) {
  String? root;
  var found = false;
  for (final path in paths) {
    if (path.isEmpty) continue;
    final parent = File(path).parent.path;
    if (!found) {
      root = parent;
      found = true;
    } else if (parent != root) {
      return null;
    }
  }
  return found ? root : null;
}

String? organizationTargetPath({
  required OrganizationWorkspaceDraft draft,
  required OrganizationWorkspaceItem item,
  required String? rootPath,
}) {
  final folder = draft.folderById(item.destinationFolderId);
  if (folder == null) return item.sourcePath;
  if (rootPath == null || rootPath.isEmpty) return null;
  return joinOrganizationPath(
    joinOrganizationPath(rootPath, folder.name),
    organizationFileName(item.sourcePath),
  );
}

String joinOrganizationPath(String parent, String child) {
  final separator = parent.contains('\\') && !parent.contains('/')
      ? '\\'
      : Platform.pathSeparator;
  if (parent.endsWith('/') || parent.endsWith('\\')) return '$parent$child';
  return '$parent$separator$child';
}

String? virtualFolderNameError(
  String value, {
  Iterable<String> existingNames = const [],
}) {
  final name = value.trim();
  if (name.isEmpty) return '請輸入資料夾名稱';
  if (name == '.' || name == '..') return '這不是有效的資料夾名稱';
  if (name.contains(RegExp(r'[\x00/\\<>:"|?*]'))) {
    return '名稱包含跨平台不安全字元';
  }
  if (name.endsWith(' ') || name.endsWith('.')) {
    return '名稱不能以空白或句點結尾';
  }
  final reserved = <String>{
    'CON',
    'PRN',
    'AUX',
    'NUL',
    for (var index = 1; index <= 9; index++) 'COM$index',
    for (var index = 1; index <= 9; index++) 'LPT$index',
  };
  if (reserved.contains(name.toUpperCase())) return '這是系統保留名稱';
  if (existingNames.any(
    (existing) => existing.trim().toLowerCase() == name.toLowerCase(),
  )) {
    return '已經有同名的虛擬資料夾';
  }
  return null;
}
