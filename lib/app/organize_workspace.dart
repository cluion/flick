import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart' as desktop_drop;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../domain/organization_workspace.dart';
import 'flick_app.dart';

class OrganizeWorkspace extends StatefulWidget {
  const OrganizeWorkspace({
    super.key,
    required this.paths,
    required this.enabled,
    required this.scanning,
    required this.onChooseFiles,
    required this.onChooseDirectory,
    required this.onRevealPath,
    required this.onCopyPath,
    required this.onDrop,
  });

  final List<String> paths;
  final bool enabled;
  final bool scanning;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;
  final ValueChanged<List<XFile>> onDrop;

  @override
  State<OrganizeWorkspace> createState() => _OrganizeWorkspaceState();
}

class _OrganizeWorkspaceState extends State<OrganizeWorkspace> {
  OrganizationWorkspaceDraft _draft = const OrganizationWorkspaceDraft();
  var _nextItemSequence = 0;
  var _nextFolderSequence = 0;
  String? _selectedFolderId;
  String? _rootPath;
  String? _notice;
  String? _error;
  var _rootWasExplicit = false;
  var _draggingExternal = false;

  String _nextItemId() => 'organization-item-${_nextItemSequence++}';

  @override
  void initState() {
    super.initState();
    _draft = _draft.reconcilePaths(widget.paths, nextItemId: _nextItemId);
    _rootPath = inferOrganizationRoot(widget.paths);
  }

  @override
  void didUpdateWidget(covariant OrganizeWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.paths == widget.paths) return;
    if (widget.paths.isEmpty) {
      setState(() {
        _draft = const OrganizationWorkspaceDraft();
        _selectedFolderId = null;
        _rootPath = null;
        _rootWasExplicit = false;
        _notice = null;
        _error = null;
      });
      return;
    }
    setState(() {
      _draft = _draft.reconcilePaths(widget.paths, nextItemId: _nextItemId);
      if (!_rootWasExplicit) _rootPath = inferOrganizationRoot(widget.paths);
    });
  }

  Future<void> _chooseRoot() async {
    try {
      final path = await getDirectoryPath(
        confirmButtonText: '選擇整理位置',
        canCreateDirectories: true,
      );
      if (path == null || !mounted) return;
      setState(() {
        _rootPath = path;
        _rootWasExplicit = true;
        _notice = '整理根目錄已設為 $path';
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error.toString());
    }
  }

  Future<void> _addFolder() async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _VirtualFolderNameDialog(
        title: '建立虛擬資料夾',
        confirmLabel: '建立',
        existingNames: _draft.folders.map((folder) => folder.name).toList(),
      ),
    );
    if (name == null || !mounted) return;
    final folder = VirtualOrganizationFolder(
      id: 'organization-folder-${_nextFolderSequence++}',
      name: name,
    );
    setState(() {
      _draft = _draft.addFolder(folder);
      _notice = '已建立虛擬資料夾「$name」；套用前不會寫入磁碟';
      _error = null;
    });
  }

  Future<void> _renameFolder(VirtualOrganizationFolder folder) async {
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _VirtualFolderNameDialog(
        title: '重新命名虛擬資料夾',
        confirmLabel: '重新命名',
        initialName: folder.name,
        existingNames: _draft.folders
            .where((candidate) => candidate.id != folder.id)
            .map((candidate) => candidate.name)
            .toList(),
      ),
    );
    if (name == null || !mounted) return;
    setState(() {
      _draft = _draft.renameFolder(folder.id, name);
      _notice = '虛擬資料夾已重新命名為「$name」';
      _error = null;
    });
  }

  void _moveItem(String itemId, String? folderId) {
    final item = _draft.items.firstWhere((candidate) => candidate.id == itemId);
    if (item.destinationFolderId == folderId) return;
    final folder = _draft.folderById(folderId);
    setState(() {
      _draft = _draft.assignItem(itemId, folderId);
      _notice = folder == null
          ? '${organizationFileName(item.sourcePath)} 已回到原位置'
          : '${organizationFileName(item.sourcePath)} 已規劃移至「${folder.name}」';
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final selectedItems = _draft.itemsInFolder(_selectedFolderId);
    final plannedMoveCount = _draft.items
        .where((item) => item.destinationFolderId != null)
        .length;
    final rootMissing = plannedMoveCount > 0 && _rootPath == null;

    return desktop_drop.DropTarget(
      onDragEntered: (_) => setState(() => _draggingExternal = true),
      onDragExited: (_) => setState(() => _draggingExternal = false),
      onDragDone: (details) {
        setState(() => _draggingExternal = false);
        widget.onDrop(details.files);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        color: _draggingExternal ? primary.withValues(alpha: 0.07) : background,
        child: Column(
          children: [
            _OrganizeToolbar(
              enabled: widget.enabled,
              scanning: widget.scanning,
              onChooseFiles: widget.onChooseFiles,
              onChooseDirectory: widget.onChooseDirectory,
            ),
            if (_error case final error?)
              _OrganizationMessageBar(
                color: danger,
                icon: Icons.error_outline_rounded,
                message: error,
                onClose: () => setState(() => _error = null),
              )
            else if (_notice case final notice?)
              _OrganizationMessageBar(
                color: mint,
                icon: Icons.check_circle_outline_rounded,
                message: notice,
                onClose: () => setState(() => _notice = null),
              ),
            if (widget.paths.isEmpty)
              Expanded(
                child: _OrganizationEmptyState(
                  enabled: widget.enabled,
                  dragging: _draggingExternal,
                  onChooseFiles: widget.onChooseFiles,
                  onChooseDirectory: widget.onChooseDirectory,
                ),
              )
            else ...[
              _OrganizationRootBar(
                rootPath: _rootPath,
                rootMissing: rootMissing,
                enabled: widget.enabled,
                onChooseRoot: () => unawaited(_chooseRoot()),
              ),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 260,
                      child: _OrganizationFolderPanel(
                        draft: _draft,
                        selectedFolderId: _selectedFolderId,
                        enabled: widget.enabled,
                        onSelectFolder: (folderId) =>
                            setState(() => _selectedFolderId = folderId),
                        onMoveItem: _moveItem,
                        onAddFolder: () => unawaited(_addFolder()),
                        onRenameFolder: (folder) =>
                            unawaited(_renameFolder(folder)),
                      ),
                    ),
                    const VerticalDivider(width: 1),
                    Expanded(
                      child: _OrganizationItemPanel(
                        draft: _draft,
                        folderId: _selectedFolderId,
                        items: selectedItems,
                        rootPath: _rootPath,
                        enabled: widget.enabled,
                        onRevealPath: widget.onRevealPath,
                        onCopyPath: widget.onCopyPath,
                      ),
                    ),
                  ],
                ),
              ),
              _OrganizationActionBar(
                folderCount: _draft.folders.length,
                plannedMoveCount: plannedMoveCount,
                unchangedCount: _draft.items.length - plannedMoveCount,
                errorCount: rootMissing ? plannedMoveCount : 0,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _OrganizeToolbar extends StatelessWidget {
  const _OrganizeToolbar({
    required this.enabled,
    required this.scanning,
    required this.onChooseFiles,
    required this.onChooseDirectory,
  });

  final bool enabled;
  final bool scanning;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '視覺整理工作區',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                SizedBox(height: 2),
                Text(
                  '先安排資料夾與最終路徑，確認前不修改磁碟',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: subtle, fontSize: 12),
                ),
              ],
            ),
          ),
          OutlinedButton.icon(
            onPressed: enabled && !scanning ? onChooseFiles : null,
            icon: const Icon(Icons.add_rounded, size: 17),
            label: const Text('加入檔案'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            onPressed: enabled && !scanning ? onChooseDirectory : null,
            icon: const Icon(Icons.folder_open_rounded, size: 17),
            label: Text(scanning ? '掃描中' : '加入資料夾'),
          ),
        ],
      ),
    );
  }
}

class _OrganizationRootBar extends StatelessWidget {
  const _OrganizationRootBar({
    required this.rootPath,
    required this.rootMissing,
    required this.enabled,
    required this.onChooseRoot,
  });

  final String? rootPath;
  final bool rootMissing;
  final bool enabled;
  final VoidCallback onChooseRoot;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 50,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: Color(0xFF0E1117),
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          Icon(
            rootMissing ? Icons.warning_amber_rounded : Icons.home_outlined,
            color: rootMissing ? warning : primaryBright,
            size: 18,
          ),
          const SizedBox(width: 8),
          const Text('整理根目錄', style: TextStyle(color: muted, fontSize: 11)),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              rootPath ?? '來源跨資料夾，請選擇最終整理位置',
              key: const ValueKey('organization-root-path'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: rootMissing ? warning : Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton.icon(
            key: const ValueKey('choose-organization-root'),
            onPressed: enabled ? onChooseRoot : null,
            icon: const Icon(Icons.drive_folder_upload_outlined, size: 17),
            label: Text(rootPath == null ? '選擇位置' : '變更'),
          ),
        ],
      ),
    );
  }
}

class _OrganizationFolderPanel extends StatelessWidget {
  const _OrganizationFolderPanel({
    required this.draft,
    required this.selectedFolderId,
    required this.enabled,
    required this.onSelectFolder,
    required this.onMoveItem,
    required this.onAddFolder,
    required this.onRenameFolder,
  });

  final OrganizationWorkspaceDraft draft;
  final String? selectedFolderId;
  final bool enabled;
  final ValueChanged<String?> onSelectFolder;
  final void Function(String itemId, String? folderId) onMoveItem;
  final VoidCallback onAddFolder;
  final ValueChanged<VirtualOrganizationFolder> onRenameFolder;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: surface,
      child: Column(
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    '虛擬資料夾',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  key: const ValueKey('organization-new-folder'),
                  onPressed: enabled ? onAddFolder : null,
                  tooltip: '建立虛擬資料夾',
                  icon: const Icon(Icons.create_new_folder_outlined, size: 19),
                ),
                const SizedBox(width: 6),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _OrganizationFolderTarget(
                  key: const ValueKey('organization-folder-root'),
                  label: '未整理（原位置）',
                  count: draft.itemsInFolder(null).length,
                  selected: selectedFolderId == null,
                  enabled: enabled,
                  virtual: false,
                  onSelect: () => onSelectFolder(null),
                  onAcceptItem: (itemId) => onMoveItem(itemId, null),
                ),
                for (final folder in draft.folders)
                  _OrganizationFolderTarget(
                    key: ValueKey(folder.id),
                    label: folder.name,
                    count: draft.itemsInFolder(folder.id).length,
                    selected: selectedFolderId == folder.id,
                    enabled: enabled,
                    virtual: true,
                    onSelect: () => onSelectFolder(folder.id),
                    onAcceptItem: (itemId) => onMoveItem(itemId, folder.id),
                    onRename: () => onRenameFolder(folder),
                  ),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.all(14),
            child: Text(
              '拖曳檔案只會更新計畫；資料夾尚未建立。',
              style: TextStyle(color: subtle, fontSize: 10, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrganizationFolderTarget extends StatelessWidget {
  const _OrganizationFolderTarget({
    super.key,
    required this.label,
    required this.count,
    required this.selected,
    required this.enabled,
    required this.virtual,
    required this.onSelect,
    required this.onAcceptItem,
    this.onRename,
  });

  final String label;
  final int count;
  final bool selected;
  final bool enabled;
  final bool virtual;
  final VoidCallback onSelect;
  final ValueChanged<String> onAcceptItem;
  final VoidCallback? onRename;

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (_) => enabled,
      onAcceptWithDetails: (details) => onAcceptItem(details.data),
      builder: (context, candidates, rejected) {
        final hovering = candidates.isNotEmpty;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Material(
            color: hovering
                ? mint.withValues(alpha: 0.13)
                : selected
                ? primary.withValues(alpha: 0.13)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(9),
            child: InkWell(
              onTap: onSelect,
              borderRadius: BorderRadius.circular(9),
              child: Container(
                height: 44,
                padding: const EdgeInsets.only(left: 10, right: 4),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: hovering
                        ? mint
                        : selected
                        ? primary.withValues(alpha: 0.45)
                        : Colors.transparent,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      virtual
                          ? Icons.folder_special_outlined
                          : Icons.inbox_outlined,
                      color: virtual ? primaryBright : muted,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '$count',
                      style: const TextStyle(color: subtle, fontSize: 10),
                    ),
                    if (onRename != null)
                      IconButton(
                        key: ValueKey('rename-organization-folder-$label'),
                        onPressed: enabled ? onRename : null,
                        tooltip: '重新命名 $label',
                        visualDensity: VisualDensity.compact,
                        icon: const Icon(
                          Icons.edit_outlined,
                          color: subtle,
                          size: 15,
                        ),
                      )
                    else
                      const SizedBox(width: 10),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _OrganizationItemPanel extends StatelessWidget {
  const _OrganizationItemPanel({
    required this.draft,
    required this.folderId,
    required this.items,
    required this.rootPath,
    required this.enabled,
    required this.onRevealPath,
    required this.onCopyPath,
  });

  final OrganizationWorkspaceDraft draft;
  final String? folderId;
  final List<OrganizationWorkspaceItem> items;
  final String? rootPath;
  final bool enabled;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;

  @override
  Widget build(BuildContext context) {
    final folder = draft.folderById(folderId);
    return Column(
      children: [
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 18),
          decoration: const BoxDecoration(
            color: surface,
            border: Border(bottom: BorderSide(color: border)),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  folder?.name ?? '未整理（原位置）',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Text(
                '${items.length} 個檔案',
                style: const TextStyle(color: subtle, fontSize: 11),
              ),
            ],
          ),
        ),
        Expanded(
          child: items.isEmpty
              ? _OrganizationFolderEmpty(folderName: folder?.name)
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: items.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final item = items[index];
                    final targetPath = organizationTargetPath(
                      draft: draft,
                      item: item,
                      rootPath: rootPath,
                    );
                    return _DraggableOrganizationItem(
                      key: ValueKey(item.id),
                      item: item,
                      targetPath: targetPath,
                      moving: item.destinationFolderId != null,
                      enabled: enabled,
                      onRevealPath: onRevealPath,
                      onCopyPath: onCopyPath,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _DraggableOrganizationItem extends StatelessWidget {
  const _DraggableOrganizationItem({
    super.key,
    required this.item,
    required this.targetPath,
    required this.moving,
    required this.enabled,
    required this.onRevealPath,
    required this.onCopyPath,
  });

  final OrganizationWorkspaceItem item;
  final String? targetPath;
  final bool moving;
  final bool enabled;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;

  @override
  Widget build(BuildContext context) {
    final name = organizationFileName(item.sourcePath);
    final card = Container(
      constraints: const BoxConstraints(minHeight: 72),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: surfaceRaised,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Row(
        children: [
          const Icon(Icons.drag_indicator_rounded, color: subtle, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  targetPath ?? '請先選擇整理根目錄',
                  key: ValueKey('organization-target-${item.id}'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: targetPath == null ? warning : subtle,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (moving ? primary : mint).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              moving ? '規劃移動' : '保留原位',
              style: TextStyle(
                color: moving ? primaryBright : mint,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          IconButton(
            onPressed: () => onRevealPath(item.sourcePath),
            tooltip: '在檔案管理器中顯示',
            icon: const Icon(Icons.folder_open_outlined, size: 17),
          ),
          IconButton(
            onPressed: () => onCopyPath(item.sourcePath),
            tooltip: '複製原始完整路徑',
            icon: const Icon(Icons.copy_rounded, size: 16),
          ),
        ],
      ),
    );
    return Draggable<String>(
      data: item.id,
      maxSimultaneousDrags: enabled ? 1 : 0,
      feedback: Material(
        color: Colors.transparent,
        child: SizedBox(
          width: 340,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: surfaceRaised,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: primaryBright),
              boxShadow: const [
                BoxShadow(color: Colors.black45, blurRadius: 18),
              ],
            ),
            child: Row(
              children: [
                const Icon(Icons.insert_drive_file_outlined, size: 17),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: card),
      child: card,
    );
  }
}

class _OrganizationFolderEmpty extends StatelessWidget {
  const _OrganizationFolderEmpty({this.folderName});

  final String? folderName;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.move_to_inbox_outlined, color: subtle, size: 36),
          const SizedBox(height: 10),
          Text(
            folderName == null ? '沒有未整理的檔案' : '拖曳檔案到「$folderName」',
            style: const TextStyle(color: muted, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          const Text(
            '選擇左側其他位置，即可繼續安排檔案',
            style: TextStyle(color: subtle, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

class _OrganizationActionBar extends StatelessWidget {
  const _OrganizationActionBar({
    required this.folderCount,
    required this.plannedMoveCount,
    required this.unchangedCount,
    required this.errorCount,
  });

  final int folderCount;
  final int plannedMoveCount;
  final int unchangedCount;
  final int errorCount;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          _OrganizationCount(label: '虛擬資料夾', count: folderCount),
          const SizedBox(width: 8),
          _OrganizationCount(label: '規劃移動', count: plannedMoveCount),
          const SizedBox(width: 8),
          _OrganizationCount(label: '保留原位', count: unchangedCount),
          if (errorCount > 0) ...[
            const SizedBox(width: 8),
            _OrganizationCount(label: '待處理', count: errorCount, color: warning),
          ],
          const Spacer(),
          Tooltip(
            message: '這一階段只建立整理預覽；安全套用與復原會在共享操作計畫完成後開放',
            child: FilledButton.icon(
              onPressed: null,
              icon: const Icon(Icons.preview_outlined, size: 17),
              label: const Text('預覽階段'),
            ),
          ),
        ],
      ),
    );
  }
}

class _OrganizationCount extends StatelessWidget {
  const _OrganizationCount({
    required this.label,
    required this.count,
    this.color = muted,
  });

  final String label;
  final int count;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$count $label',
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _OrganizationEmptyState extends StatelessWidget {
  const _OrganizationEmptyState({
    required this.enabled,
    required this.dragging,
    required this.onChooseFiles,
    required this.onChooseDirectory,
  });

  final bool enabled;
  final bool dragging;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            dragging ? Icons.file_download_done_rounded : Icons.account_tree,
            color: dragging ? mint : subtle,
            size: 42,
          ),
          const SizedBox(height: 14),
          const Text(
            '加入檔案，開始規劃資料夾',
            style: TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 5),
          const Text(
            '你也可以把檔案或資料夾拖放到這裡',
            style: TextStyle(color: subtle, fontSize: 12),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              FilledButton.icon(
                onPressed: enabled ? onChooseFiles : null,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text('選擇檔案'),
              ),
              const SizedBox(width: 9),
              OutlinedButton.icon(
                onPressed: enabled ? onChooseDirectory : null,
                icon: const Icon(Icons.folder_open_rounded, size: 18),
                label: const Text('選擇資料夾'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _VirtualFolderNameDialog extends StatefulWidget {
  const _VirtualFolderNameDialog({
    required this.title,
    required this.confirmLabel,
    required this.existingNames,
    this.initialName = '',
  });

  final String title;
  final String confirmLabel;
  final List<String> existingNames;
  final String initialName;

  @override
  State<_VirtualFolderNameDialog> createState() =>
      _VirtualFolderNameDialogState();
}

class _VirtualFolderNameDialogState extends State<_VirtualFolderNameDialog> {
  late final TextEditingController _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
    _controller.selection = TextSelection(
      baseOffset: 0,
      extentOffset: widget.initialName.length,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final error = virtualFolderNameError(
      _controller.text,
      existingNames: widget.existingNames,
    );
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.pop(context, _controller.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceRaised,
      title: Text(widget.title),
      content: SizedBox(
        width: 420,
        child: TextField(
          key: const ValueKey('virtual-folder-name-field'),
          controller: _controller,
          autofocus: true,
          onChanged: (_) {
            if (_error != null) setState(() => _error = null);
          },
          onSubmitted: (_) => _submit(),
          decoration: InputDecoration(
            labelText: '資料夾名稱',
            errorText: _error,
            helperText: '目前只建立預覽，不會立即在磁碟建立資料夾',
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: Text(widget.confirmLabel)),
      ],
    );
  }
}

class _OrganizationMessageBar extends StatelessWidget {
  const _OrganizationMessageBar({
    required this.color,
    required this.icon,
    required this.message,
    required this.onClose,
  });

  final Color color;
  final IconData icon;
  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 48),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      color: color.withValues(alpha: 0.1),
      child: Row(
        children: [
          Icon(icon, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            onPressed: onClose,
            tooltip: '關閉訊息',
            icon: Icon(Icons.close_rounded, color: color, size: 17),
          ),
        ],
      ),
    );
  }
}
