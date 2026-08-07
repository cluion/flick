import 'dart:async';

import 'package:bridra_flutter/bridra_flutter.dart' show RpcException;
import 'package:desktop_drop/desktop_drop.dart' as desktop_drop;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../api/backend_gateway.dart';
import '../domain/organization_workspace.dart';
import 'flick_app.dart';

class OrganizeWorkspace extends StatefulWidget {
  const OrganizeWorkspace({
    super.key,
    required this.paths,
    required this.backend,
    required this.active,
    required this.enabled,
    required this.scanning,
    required this.onChooseFiles,
    required this.onChooseDirectory,
    required this.onRevealPath,
    required this.onCopyPath,
    required this.onDrop,
    required this.onApplyingChanged,
    required this.onApplied,
  });

  final List<String> paths;
  final BackendGateway? backend;
  final bool active;
  final bool enabled;
  final bool scanning;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;
  final ValueChanged<List<XFile>> onDrop;
  final ValueChanged<bool> onApplyingChanged;
  final ValueChanged<String> onApplied;

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
  OrganizationPlan? _plan;
  Timer? _previewTimer;
  var _previewGeneration = 0;
  var _previewing = false;
  var _applying = false;
  var _rootWasExplicit = false;
  var _draggingExternal = false;

  String _nextItemId() => 'organization-item-${_nextItemSequence++}';

  @override
  void initState() {
    super.initState();
    _draft = _draft.reconcilePaths(widget.paths, nextItemId: _nextItemId);
    _rootPath = inferOrganizationRoot(widget.paths);
    if (widget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _schedulePreview(immediate: true);
      });
    }
  }

  @override
  void didUpdateWidget(covariant OrganizeWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pathsChanged = oldWidget.paths != widget.paths;
    final backendChanged = oldWidget.backend != widget.backend;
    final activated = !oldWidget.active && widget.active;
    if (!pathsChanged && !backendChanged && !activated) return;
    if (pathsChanged && widget.paths.isEmpty) {
      _previewTimer?.cancel();
      _previewGeneration++;
      setState(() {
        _draft = const OrganizationWorkspaceDraft();
        _selectedFolderId = null;
        _rootPath = null;
        _rootWasExplicit = false;
        _notice = null;
        _error = null;
        _plan = null;
        _previewing = false;
      });
      return;
    }
    if (pathsChanged) {
      setState(() {
        _draft = _draft.reconcilePaths(widget.paths, nextItemId: _nextItemId);
        if (!_rootWasExplicit) _rootPath = inferOrganizationRoot(widget.paths);
        _plan = null;
      });
    }
    if (widget.active) _schedulePreview(immediate: true);
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    super.dispose();
  }

  void _schedulePreview({bool immediate = false}) {
    _previewTimer?.cancel();
    final generation = ++_previewGeneration;
    final backend = widget.backend;
    final rootPath = _rootPath;
    if (_applying ||
        !widget.active ||
        backend == null ||
        rootPath == null ||
        _draft.items.isEmpty) {
      if (mounted) {
        setState(() {
          _plan = null;
          _previewing = false;
        });
      }
      return;
    }
    if (!_previewing) setState(() => _previewing = true);
    if (immediate) {
      unawaited(_preview(generation, backend, rootPath));
      return;
    }
    _previewTimer = Timer(const Duration(milliseconds: 180), () {
      _previewTimer = null;
      unawaited(_preview(generation, backend, rootPath));
    });
  }

  Future<void> _preview(
    int generation,
    BackendGateway backend,
    String rootPath,
  ) async {
    try {
      final plan = await backend.previewOrganization(
        PreviewOrganizationRequest(
          rootPath: rootPath,
          folderIds: _draft.folders
              .map((folder) => folder.id)
              .toList(growable: false),
          folderNames: _draft.folders
              .map((folder) => folder.name)
              .toList(growable: false),
          itemIds: _draft.items.map((item) => item.id).toList(growable: false),
          sourcePaths: _draft.items
              .map((item) => item.sourcePath)
              .toList(growable: false),
          destinationFolderIds: _draft.items
              .map((item) => item.destinationFolderId ?? '')
              .toList(growable: false),
        ),
      );
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _plan = plan;
        _error = null;
      });
    } on Object catch (error) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _plan = null;
        _error = _friendlyOrganizationError(error);
      });
    } finally {
      if (mounted && generation == _previewGeneration) {
        setState(() => _previewing = false);
      }
    }
  }

  Future<void> _apply() async {
    final backend = widget.backend;
    final plan = _plan;
    if (backend == null ||
        plan == null ||
        plan.errorCount > 0 ||
        plan.crossVolumeCount > 0 ||
        (plan.mkdirCount == 0 && plan.moveCount == 0) ||
        _previewing ||
        _applying) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceRaised,
        title: const Text('套用檔案整理？'),
        content: Text(
          '將建立 ${plan.mkdirCount} 個資料夾並移動 ${plan.moveCount} 個檔案。'
          'Flick 會在動作前重新驗證，失敗時自動回滾。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-organization-apply'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('開始整理'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _applying = true;
      _error = null;
      _notice = null;
    });
    widget.onApplyingChanged(true);
    try {
      final result = await backend.applyOrganization(
        ApplyOrganizationRequest(planId: plan.planId),
      );
      if (!mounted) return;
      setState(() => _plan = null);
      widget.onApplied(
        '已安全建立 ${result.createdFolderCount} 個資料夾並移動 ${result.movedCount} 個檔案',
      );
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = _friendlyOrganizationError(error));
      }
    } finally {
      if (mounted) setState(() => _applying = false);
      widget.onApplyingChanged(false);
    }
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
        _plan = null;
      });
      _schedulePreview(immediate: true);
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
      _plan = null;
    });
    _schedulePreview();
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
      _plan = null;
    });
    _schedulePreview();
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
      _plan = null;
    });
    _schedulePreview();
  }

  @override
  Widget build(BuildContext context) {
    final workspaceEnabled = widget.enabled && !_applying;
    final selectedItems = _draft.itemsInFolder(_selectedFolderId);
    final localMoveCount = _draft.items
        .where((item) => item.destinationFolderId != null)
        .length;
    final rootMissing = localMoveCount > 0 && _rootPath == null;
    final plan = _plan;
    final plannedMoveCount = plan?.moveCount ?? localMoveCount;
    final unchangedCount =
        plan?.unchangedCount ?? _draft.items.length - localMoveCount;
    final errorCount = plan?.errorCount ?? (rootMissing ? localMoveCount : 0);

    return desktop_drop.DropTarget(
      onDragEntered: (_) {
        if (workspaceEnabled) setState(() => _draggingExternal = true);
      },
      onDragExited: (_) => setState(() => _draggingExternal = false),
      onDragDone: (details) {
        setState(() => _draggingExternal = false);
        if (workspaceEnabled) widget.onDrop(details.files);
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        color: _draggingExternal ? primary.withValues(alpha: 0.07) : background,
        child: Column(
          children: [
            _OrganizeToolbar(
              enabled: workspaceEnabled,
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
                  enabled: workspaceEnabled,
                  dragging: _draggingExternal,
                  onChooseFiles: widget.onChooseFiles,
                  onChooseDirectory: widget.onChooseDirectory,
                ),
              )
            else ...[
              _OrganizationRootBar(
                rootPath: _rootPath,
                rootMissing: rootMissing,
                verified: plan != null && !_previewing,
                enabled: workspaceEnabled,
                onChooseRoot: () => unawaited(_chooseRoot()),
              ),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 260,
                      child: _OrganizationFolderPanel(
                        draft: _draft,
                        plan: plan,
                        selectedFolderId: _selectedFolderId,
                        enabled: workspaceEnabled,
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
                        plan: plan,
                        folderId: _selectedFolderId,
                        items: selectedItems,
                        rootPath: _rootPath,
                        enabled: workspaceEnabled,
                        onRevealPath: widget.onRevealPath,
                        onCopyPath: widget.onCopyPath,
                      ),
                    ),
                  ],
                ),
              ),
              _OrganizationActionBar(
                folderCount: plan?.mkdirCount ?? _draft.folders.length,
                plannedMoveCount: plannedMoveCount,
                unchangedCount: unchangedCount,
                crossVolumeCount: plan?.crossVolumeCount ?? 0,
                errorCount: errorCount,
                previewing: _previewing,
                applying: _applying,
                canApply:
                    workspaceEnabled &&
                    plan != null &&
                    !_previewing &&
                    plan.errorCount == 0 &&
                    plan.crossVolumeCount == 0 &&
                    (plan.mkdirCount > 0 || plan.moveCount > 0),
                onApply: () => unawaited(_apply()),
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
    required this.verified,
    required this.enabled,
    required this.onChooseRoot,
  });

  final String? rootPath;
  final bool rootMissing;
  final bool verified;
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
          if (verified) ...[
            const Icon(Icons.verified_outlined, color: mint, size: 15),
            const SizedBox(width: 5),
            const Text(
              'Go 已驗證',
              key: ValueKey('organization-backend-verified'),
              style: TextStyle(
                color: mint,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(width: 5),
          ],
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
    required this.plan,
    required this.selectedFolderId,
    required this.enabled,
    required this.onSelectFolder,
    required this.onMoveItem,
    required this.onAddFolder,
    required this.onRenameFolder,
  });

  final OrganizationWorkspaceDraft draft;
  final OrganizationPlan? plan;
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
                    virtual:
                        _organizationFolderPreview(plan, folder.id)?.created ??
                        true,
                    status: _organizationFolderPreview(plan, folder.id)?.status,
                    message: _organizationFolderPreview(
                      plan,
                      folder.id,
                    )?.message,
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
    this.status,
    this.message,
  });

  final String label;
  final int count;
  final bool selected;
  final bool enabled;
  final bool virtual;
  final String? status;
  final String? message;
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
                    Tooltip(
                      message: _localizedOrganizationMessage(
                        message,
                        fallback: status == 'existing'
                            ? '磁碟上已有此資料夾，套用時會直接使用'
                            : virtual
                            ? '套用時將建立這個資料夾'
                            : '檔案目前保留在原位置',
                      ),
                      child: Icon(
                        status == 'error'
                            ? Icons.error_outline_rounded
                            : virtual
                            ? Icons.folder_special_outlined
                            : status == 'existing'
                            ? Icons.folder_outlined
                            : Icons.inbox_outlined,
                        color: status == 'error'
                            ? danger
                            : virtual
                            ? primaryBright
                            : status == 'existing'
                            ? mint
                            : muted,
                        size: 18,
                      ),
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
    required this.plan,
    required this.folderId,
    required this.items,
    required this.rootPath,
    required this.enabled,
    required this.onRevealPath,
    required this.onCopyPath,
  });

  final OrganizationWorkspaceDraft draft;
  final OrganizationPlan? plan;
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
                    final preview = _organizationItemPreview(plan, item.id);
                    final targetPath =
                        preview?.targetPath ??
                        organizationTargetPath(
                          draft: draft,
                          item: item,
                          rootPath: rootPath,
                        );
                    return _DraggableOrganizationItem(
                      key: ValueKey(item.id),
                      item: item,
                      targetPath: targetPath,
                      moving: item.destinationFolderId != null,
                      status: preview?.status,
                      message: preview?.message,
                      crossVolume: preview?.crossVolume ?? false,
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
    required this.status,
    required this.message,
    required this.crossVolume,
    required this.enabled,
    required this.onRevealPath,
    required this.onCopyPath,
  });

  final OrganizationWorkspaceItem item;
  final String? targetPath;
  final bool moving;
  final String? status;
  final String? message;
  final bool crossVolume;
  final bool enabled;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;

  @override
  Widget build(BuildContext context) {
    final name = organizationFileName(item.sourcePath);
    final error = status == 'error';
    final statusLabel = error
        ? '待處理'
        : crossVolume
        ? '跨磁碟'
        : moving
        ? '規劃移動'
        : '保留原位';
    final statusColor = error
        ? danger
        : crossVolume
        ? warning
        : moving
        ? primaryBright
        : mint;
    final card = Container(
      constraints: BoxConstraints(minHeight: error ? 86 : 72),
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
                if (error) ...[
                  const SizedBox(height: 3),
                  Text(
                    _localizedOrganizationMessage(
                      message,
                      fallback: '整理計畫需要先處理這個項目',
                    ),
                    key: ValueKey('organization-error-${item.id}'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: danger, fontSize: 10),
                  ),
                ],
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
              color: statusColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(
              statusLabel,
              style: TextStyle(
                color: statusColor,
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
    required this.crossVolumeCount,
    required this.errorCount,
    required this.previewing,
    required this.applying,
    required this.canApply,
    required this.onApply,
  });

  final int folderCount;
  final int plannedMoveCount;
  final int unchangedCount;
  final int crossVolumeCount;
  final int errorCount;
  final bool previewing;
  final bool applying;
  final bool canApply;
  final VoidCallback onApply;

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
          _OrganizationCount(label: '將建立', count: folderCount),
          const SizedBox(width: 8),
          _OrganizationCount(label: '規劃移動', count: plannedMoveCount),
          const SizedBox(width: 8),
          _OrganizationCount(label: '保留原位', count: unchangedCount),
          if (crossVolumeCount > 0) ...[
            const SizedBox(width: 8),
            _OrganizationCount(
              label: '跨磁碟',
              count: crossVolumeCount,
              color: warning,
            ),
          ],
          if (errorCount > 0) ...[
            const SizedBox(width: 8),
            _OrganizationCount(label: '待處理', count: errorCount, color: warning),
          ],
          const Spacer(),
          Tooltip(
            message: crossVolumeCount > 0
                ? '跨磁碟搬移尚未開放；請改用同一個磁碟的整理根目錄'
                : errorCount > 0
                ? '請先修正所有待處理項目'
                : '套用前會重新驗證，執行失敗會自動回滾',
            child: FilledButton.icon(
              key: const ValueKey('apply-organization'),
              onPressed: canApply ? onApply : null,
              icon: previewing || applying
                  ? const SizedBox.square(
                      dimension: 15,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.drive_file_move_outline, size: 17),
              label: Text(
                previewing
                    ? '驗證中'
                    : applying
                    ? '正在整理…'
                    : '開始整理',
              ),
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

({bool created, String status, String message})? _organizationFolderPreview(
  OrganizationPlan? plan,
  String folderId,
) {
  if (plan == null) return null;
  final index = plan.folderIds.indexOf(folderId);
  if (index < 0 ||
      index >= plan.folderCreated.length ||
      index >= plan.folderStatuses.length ||
      index >= plan.folderMessages.length) {
    return null;
  }
  return (
    created: plan.folderCreated[index],
    status: plan.folderStatuses[index],
    message: plan.folderMessages[index],
  );
}

({String targetPath, String status, String message, bool crossVolume})?
_organizationItemPreview(OrganizationPlan? plan, String itemId) {
  if (plan == null) return null;
  final index = plan.itemIds.indexOf(itemId);
  if (index < 0 ||
      index >= plan.targetPaths.length ||
      index >= plan.itemStatuses.length ||
      index >= plan.itemMessages.length ||
      index >= plan.itemCrossVolume.length) {
    return null;
  }
  return (
    targetPath: plan.targetPaths[index],
    status: plan.itemStatuses[index],
    message: plan.itemMessages[index],
    crossVolume: plan.itemCrossVolume[index],
  );
}

String _friendlyOrganizationError(Object error) {
  if (error is RpcException) {
    return switch (error.code) {
      'invalid_organization' => '整理計畫資料不一致，請重新加入檔案後再試',
      'invalid_organization_root' => '請先選擇有效的整理根目錄',
      'organization_root_unavailable' => '整理根目錄不存在或無法讀取',
      'organization_root_required' => '整理根目錄必須是一般資料夾，不能是連結',
      'organization_root_read_only' => '整理根目錄目前無法寫入',
      'empty_selection' => '請先加入至少一個檔案',
      'too_many_items' => '整理項目超過上限，請縮小範圍',
      'too_many_folders' => '虛擬資料夾數量超過上限',
      'plan_expired' => '整理預覽已過期，請稍候重新預覽後再試',
      'invalid_plan' => '請先修正所有整理預覽錯誤',
      'nothing_to_organize' => '目前沒有需要套用的整理動作',
      'source_changed' => '來源檔案在預覽後有變更，請重新確認整理結果',
      'target_changed' => '目的路徑在預覽後有變更，已停止並回滾整理',
      'plan_changed' => '磁碟或整理位置已變更，請重新確認整理結果',
      'cross_volume_unsupported' => '目前只支援同磁碟整理；跨磁碟搬移尚未開放',
      'organization_apply_rolled_back' => '整理執行失敗，但所有檔案與新資料夾都已安全回滾',
      'organization_recovery_required' => '整理未能完整復原，Flick 已停止後續套用；請保留現場並檢查操作日誌',
      _ => error.message,
    };
  }
  return error.toString();
}

String _localizedOrganizationMessage(
  String? message, {
  required String fallback,
}) {
  return switch (message) {
    null || '' => fallback,
    'This folder already exists and will be reused.' => '磁碟上已有此資料夾，套用時會直接使用',
    'Multiple virtual folders have the same name.' => '有多個同名的虛擬資料夾',
    'A non-folder item already occupies this path.' => '此路徑已被非資料夾項目占用',
    'The destination folder is not writable.' => '目的資料夾目前無法寫入',
    'The destination folder cannot be inspected.' => '無法檢查目的資料夾',
    'The destination folder must be fixed first.' => '請先修正目的資料夾',
    'The destination virtual folder does not exist.' => '目的虛擬資料夾不存在',
    'The source path is invalid.' => '來源路徑無效',
    'The source file is missing or inaccessible.' => '來源檔案不存在或無法讀取',
    'Only regular files can be organized.' => '目前只支援整理一般檔案',
    'The same source file was added more than once.' => '同一個來源檔案被重複加入',
    'Multiple files would occupy the same target path.' => '多個檔案會占用相同的最終路徑',
    'The target path cannot be inspected.' => '無法檢查最終路徑',
    'An unrelated item already occupies the target path.' => '最終路徑已被其他項目占用',
    'An occupied target will not be moved away by this plan.' =>
      '最終路徑上的檔案不會被此計畫移走',
    'The destination filesystem cannot be classified.' => '無法判斷來源與目的磁碟',
    _ => message,
  };
}
