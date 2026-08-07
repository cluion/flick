import 'dart:async';
import 'dart:math' as math;

import 'package:bridra_flutter/bridra_flutter.dart' show RpcException;
import 'package:desktop_drop/desktop_drop.dart' as desktop_drop;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../api/backend_gateway.dart';
import '../domain/collision_strategy.dart';
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
    required this.collisionStrategy,
    required this.onCollisionStrategyChanged,
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
  final CollisionStrategy collisionStrategy;
  final ValueChanged<CollisionStrategy> onCollisionStrategyChanged;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;
  final ValueChanged<List<XFile>> onDrop;
  final ValueChanged<bool> onApplyingChanged;
  final Future<void> Function(String) onApplied;

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
  var _showOnlyErrors = false;
  final Map<OrganizationCategory, String> _categoryFolderIds = {};

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
    final collisionStrategyChanged =
        oldWidget.collisionStrategy != widget.collisionStrategy;
    if (!pathsChanged &&
        !backendChanged &&
        !activated &&
        !collisionStrategyChanged) {
      return;
    }
    if (pathsChanged && widget.paths.isEmpty) {
      _previewTimer?.cancel();
      _previewGeneration++;
      setState(() {
        _draft = const OrganizationWorkspaceDraft();
        _categoryFolderIds.clear();
        _selectedFolderId = null;
        _showOnlyErrors = false;
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
          collisionStrategy: widget.collisionStrategy.wireName,
        ),
      );
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _plan = plan;
        if (plan.errorCount == 0) _showOnlyErrors = false;
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
      await widget.onApplied(
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

  void _classifyUnassigned(OrganizationCategory? requestedCategory) {
    final plan = _plan;
    if (plan == null || _previewing || _applying) return;
    final itemIdsByCategory = _unassignedCategoryItemIds(plan, _draft);
    final categories = requestedCategory == null
        ? OrganizationCategory.values
        : [requestedCategory];
    var nextDraft = _draft;
    final nextFolderIds = Map<OrganizationCategory, String>.of(
      _categoryFolderIds,
    );
    var assignedCount = 0;
    String? selectedFolderId;
    for (final category in categories) {
      final itemIds = itemIdsByCategory[category] ?? const <String>[];
      if (itemIds.isEmpty) continue;
      var folder = _categoryFolder(category, nextDraft, nextFolderIds);
      if (folder == null) {
        folder = VirtualOrganizationFolder(
          id: 'organization-folder-${_nextFolderSequence++}',
          name: category.folderName,
        );
        nextDraft = nextDraft.addFolder(folder);
      }
      nextFolderIds[category] = folder.id;
      nextDraft = nextDraft.assignItems(itemIds, folder.id);
      assignedCount += itemIds.length;
      if (requestedCategory != null) selectedFolderId = folder.id;
    }
    if (assignedCount == 0) {
      setState(() {
        _notice = requestedCategory == null
            ? '目前沒有尚未整理的檔案'
            : '目前沒有尚未整理的「${requestedCategory.folderName}」檔案';
        _error = null;
      });
      return;
    }
    setState(() {
      _draft = nextDraft;
      _categoryFolderIds
        ..clear()
        ..addAll(nextFolderIds);
      if (selectedFolderId != null) _selectedFolderId = selectedFolderId;
      _showOnlyErrors = false;
      _notice = requestedCategory == null
          ? '已依偵測結果規劃 $assignedCount 個檔案；套用前不會寫入磁碟'
          : '已將 $assignedCount 個檔案規劃至「${requestedCategory.folderName}」';
      _error = null;
      _plan = null;
    });
    _schedulePreview(immediate: true);
  }

  VirtualOrganizationFolder? _categoryFolder(
    OrganizationCategory category,
    OrganizationWorkspaceDraft draft,
    Map<OrganizationCategory, String> folderIds,
  ) {
    final mapped = draft.folderById(folderIds[category]);
    if (mapped != null) return mapped;
    for (final folder in draft.folders) {
      if (folder.name.trim().toLowerCase() ==
          category.folderName.toLowerCase()) {
        return folder;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final workspaceEnabled = widget.enabled && !_applying;
    final selectedItems = _showOnlyErrors
        ? _organizationErrorItems(_plan, _draft)
        : _draft.itemsInFolder(_selectedFolderId);
    final localMoveCount = _draft.items
        .where((item) => item.destinationFolderId != null)
        .length;
    final rootMissing = localMoveCount > 0 && _rootPath == null;
    final plan = _plan;
    final plannedMoveCount = plan?.moveCount ?? localMoveCount;
    final unchangedCount =
        plan?.unchangedCount ?? _draft.items.length - localMoveCount;
    final errorCount = plan?.errorCount ?? (rootMissing ? localMoveCount : 0);
    final quickCategoryCounts = _unassignedCategoryCounts(plan, _draft);

    return desktop_drop.DropTarget(
      enable: widget.active && workspaceEnabled,
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
              _OrganizationCategoryBar(
                counts: quickCategoryCounts,
                enabled: workspaceEnabled && plan != null && !_previewing,
                previewing: _previewing,
                onClassify: _classifyUnassigned,
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
                        showingErrors: _showOnlyErrors,
                        enabled: workspaceEnabled,
                        onSelectFolder: (folderId) => setState(() {
                          _selectedFolderId = folderId;
                          _showOnlyErrors = false;
                        }),
                        onShowErrors: () =>
                            setState(() => _showOnlyErrors = true),
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
                        showingErrors: _showOnlyErrors,
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
                collisionStrategy: widget.collisionStrategy,
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
                onCollisionStrategyChanged: widget.onCollisionStrategyChanged,
                onShowErrors: () => setState(() => _showOnlyErrors = true),
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

class _OrganizationCategoryBar extends StatelessWidget {
  const _OrganizationCategoryBar({
    required this.counts,
    required this.enabled,
    required this.previewing,
    required this.onClassify,
  });

  final Map<OrganizationCategory, int> counts;
  final bool enabled;
  final bool previewing;
  final ValueChanged<OrganizationCategory?> onClassify;

  @override
  Widget build(BuildContext context) {
    final total = counts.values.fold<int>(0, (sum, count) => sum + count);
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          Tooltip(
            message: 'Go 會先檢查檔案內容特徵，再以副檔名補足分類',
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.auto_awesome_outlined, color: mint, size: 17),
                const SizedBox(width: 7),
                Text(
                  previewing ? '辨識中' : '快速分類',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          FilledButton.tonalIcon(
            key: const ValueKey('organization-classify-all'),
            onPressed: enabled && total > 0 ? () => onClassify(null) : null,
            icon: const Icon(Icons.auto_awesome_rounded, size: 16),
            label: Text('全部分類${total > 0 ? ' $total' : ''}'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
          ),
          const SizedBox(width: 10),
          const VerticalDivider(width: 1, indent: 10, endIndent: 10),
          const SizedBox(width: 10),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final category in OrganizationCategory.values) ...[
                    OutlinedButton.icon(
                      key: ValueKey(
                        'organization-classify-${category.wireName}',
                      ),
                      onPressed: enabled && (counts[category] ?? 0) > 0
                          ? () => onClassify(category)
                          : null,
                      icon: Icon(_organizationCategoryIcon(category), size: 15),
                      label: Text(
                        '${category.folderName} ${counts[category] ?? 0}',
                      ),
                      style: OutlinedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                      ),
                    ),
                    if (category != OrganizationCategory.values.last)
                      const SizedBox(width: 7),
                  ],
                ],
              ),
            ),
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
    required this.showingErrors,
    required this.enabled,
    required this.onSelectFolder,
    required this.onShowErrors,
    required this.onMoveItem,
    required this.onAddFolder,
    required this.onRenameFolder,
  });

  final OrganizationWorkspaceDraft draft;
  final OrganizationPlan? plan;
  final String? selectedFolderId;
  final bool showingErrors;
  final bool enabled;
  final ValueChanged<String?> onSelectFolder;
  final VoidCallback onShowErrors;
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
                if ((plan?.errorCount ?? 0) > 0)
                  _OrganizationErrorTarget(
                    count: plan!.errorCount,
                    selected: showingErrors,
                    onSelect: onShowErrors,
                  ),
                _OrganizationFolderTarget(
                  key: const ValueKey('organization-folder-root'),
                  label: '未整理（原位置）',
                  count: draft.itemsInFolder(null).length,
                  selected: selectedFolderId == null && !showingErrors,
                  enabled: enabled,
                  virtual: false,
                  errorCount: _organizationFolderItemErrorCount(
                    plan,
                    draft,
                    null,
                  ),
                  onSelect: () => onSelectFolder(null),
                  onAcceptItem: (itemId) => onMoveItem(itemId, null),
                ),
                for (final folder in draft.folders)
                  _OrganizationFolderTarget(
                    key: ValueKey(folder.id),
                    label: folder.name,
                    count: draft.itemsInFolder(folder.id).length,
                    selected: selectedFolderId == folder.id && !showingErrors,
                    enabled: enabled,
                    errorCount: _organizationFolderItemErrorCount(
                      plan,
                      draft,
                      folder.id,
                    ),
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

class _OrganizationErrorTarget extends StatelessWidget {
  const _OrganizationErrorTarget({
    required this.count,
    required this.selected,
    required this.onSelect,
  });

  final int count;
  final bool selected;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Material(
        color: selected
            ? warning.withValues(alpha: 0.13)
            : warning.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(9),
        child: InkWell(
          key: const ValueKey('organization-folder-errors'),
          onTap: onSelect,
          borderRadius: BorderRadius.circular(9),
          child: Container(
            height: 44,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(9),
              border: Border.all(
                color: selected
                    ? warning.withValues(alpha: 0.7)
                    : Colors.transparent,
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.warning_amber_rounded,
                  color: warning,
                  size: 17,
                ),
                const SizedBox(width: 9),
                const Expanded(
                  child: Text(
                    '全部待處理',
                    style: TextStyle(
                      color: warning,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$count',
                  style: const TextStyle(
                    color: warning,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
        ),
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
    this.errorCount = 0,
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
  final int errorCount;
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
                    if (errorCount > 0) ...[
                      const SizedBox(width: 7),
                      Container(
                        key: ValueKey('organization-folder-errors-$label'),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: warning.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.warning_amber_rounded,
                              color: warning,
                              size: 11,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              '$errorCount',
                              style: const TextStyle(
                                color: warning,
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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
    required this.showingErrors,
    required this.items,
    required this.rootPath,
    required this.enabled,
    required this.onRevealPath,
    required this.onCopyPath,
  });

  final OrganizationWorkspaceDraft draft;
  final OrganizationPlan? plan;
  final String? folderId;
  final bool showingErrors;
  final List<OrganizationWorkspaceItem> items;
  final String? rootPath;
  final bool enabled;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;

  @override
  Widget build(BuildContext context) {
    final folder = draft.folderById(folderId);
    final title = showingErrors ? '全部待處理' : folder?.name ?? '未整理（原位置）';
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
                  title,
                  key: const ValueKey('organization-item-panel-title'),
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
              ? _OrganizationFolderEmpty(
                  folderName: folder?.name,
                  showingErrors: showingErrors,
                )
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
                      category: preview?.category,
                      categoryReason: preview?.categoryReason,
                      collisionResolved: preview?.collisionResolved ?? false,
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
    required this.category,
    required this.categoryReason,
    required this.collisionResolved,
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
  final OrganizationCategory? category;
  final String? categoryReason;
  final bool collisionResolved;
  final bool enabled;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;

  @override
  Widget build(BuildContext context) {
    final name = organizationFileName(item.sourcePath);
    final error = status == 'error';
    final statusLabel = error
        ? '待處理'
        : collisionResolved
        ? '已加編號'
        : crossVolume
        ? '跨磁碟'
        : moving
        ? '規劃移動'
        : '保留原位';
    final statusColor = error
        ? danger
        : collisionResolved
        ? mint
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (category case final detectedCategory?) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: _localizedOrganizationCategoryReason(
                          detectedCategory,
                          categoryReason,
                        ),
                        child: Container(
                          key: ValueKey('organization-category-${item.id}'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: _organizationCategoryColor(
                              detectedCategory,
                            ).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(999),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                _organizationCategoryIcon(detectedCategory),
                                color: _organizationCategoryColor(
                                  detectedCategory,
                                ),
                                size: 11,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                detectedCategory.folderName,
                                style: TextStyle(
                                  color: _organizationCategoryColor(
                                    detectedCategory,
                                  ),
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
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
  const _OrganizationFolderEmpty({this.folderName, this.showingErrors = false});

  final String? folderName;
  final bool showingErrors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.move_to_inbox_outlined, color: subtle, size: 36),
          const SizedBox(height: 10),
          Text(
            showingErrors
                ? '目前沒有待處理項目'
                : folderName == null
                ? '沒有未整理的檔案'
                : '拖曳檔案到「$folderName」',
            style: const TextStyle(color: muted, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          Text(
            showingErrors ? '所有目標路徑均已通過驗證' : '選擇左側其他位置，即可繼續安排檔案',
            style: const TextStyle(color: subtle, fontSize: 11),
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
    required this.collisionStrategy,
    required this.previewing,
    required this.applying,
    required this.canApply,
    required this.onApply,
    required this.onCollisionStrategyChanged,
    required this.onShowErrors,
  });

  final int folderCount;
  final int plannedMoveCount;
  final int unchangedCount;
  final int crossVolumeCount;
  final int errorCount;
  final CollisionStrategy collisionStrategy;
  final bool previewing;
  final bool applying;
  final bool canApply;
  final VoidCallback onApply;
  final ValueChanged<CollisionStrategy> onCollisionStrategyChanged;
  final VoidCallback onShowErrors;

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
            _OrganizationCount(
              key: const ValueKey('organization-error-count'),
              label: '待處理',
              count: errorCount,
              color: warning,
              onTap: onShowErrors,
            ),
          ],
          const Spacer(),
          SizedBox(
            width: 168,
            child: _OrganizationCollisionStrategyPicker(
              strategy: collisionStrategy,
              enabled: !previewing && !applying,
              onChanged: onCollisionStrategyChanged,
            ),
          ),
          const SizedBox(width: 10),
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
    super.key,
    required this.label,
    required this.count,
    this.color = muted,
    this.onTap,
  });

  final String label;
  final int count;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final content = Container(
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
    if (onTap == null) return content;
    return Tooltip(
      message: '顯示全部待處理項目',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: content,
      ),
    );
  }
}

class _OrganizationCollisionStrategyPicker extends StatelessWidget {
  const _OrganizationCollisionStrategyPicker({
    required this.strategy,
    required this.enabled,
    required this.onChanged,
  });

  final CollisionStrategy strategy;
  final bool enabled;
  final ValueChanged<CollisionStrategy> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: switch (strategy) {
        CollisionStrategy.fail => '安全預設：重複目標會列為待處理並阻止套用',
        CollisionStrategy.appendNumber => '在副檔名前附加 (2)、(3)…，絕不覆寫原檔',
      },
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1117),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<CollisionStrategy>(
            key: const ValueKey('organization-collision-strategy'),
            value: strategy,
            isExpanded: true,
            icon: const Icon(Icons.expand_more_rounded, size: 17),
            items: CollisionStrategy.values
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(
                      value.label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 11),
                    ),
                  ),
                )
                .toList(growable: false),
            onChanged: enabled
                ? (value) {
                    if (value != null) onChanged(value);
                  }
                : null,
          ),
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

({
  String targetPath,
  String status,
  String message,
  bool crossVolume,
  OrganizationCategory? category,
  String categoryReason,
  bool collisionResolved,
})?
_organizationItemPreview(OrganizationPlan? plan, String itemId) {
  if (plan == null) return null;
  final index = plan.itemIds.indexOf(itemId);
  if (index < 0 ||
      index >= plan.targetPaths.length ||
      index >= plan.itemStatuses.length ||
      index >= plan.itemMessages.length ||
      index >= plan.itemCrossVolume.length ||
      index >= plan.itemCategories.length ||
      index >= plan.itemCategoryReasons.length ||
      index >= plan.itemCollisionResolved.length) {
    return null;
  }
  return (
    targetPath: plan.targetPaths[index],
    status: plan.itemStatuses[index],
    message: plan.itemMessages[index],
    crossVolume: plan.itemCrossVolume[index],
    category: OrganizationCategory.fromWireName(plan.itemCategories[index]),
    categoryReason: plan.itemCategoryReasons[index],
    collisionResolved: plan.itemCollisionResolved[index],
  );
}

List<OrganizationWorkspaceItem> _organizationErrorItems(
  OrganizationPlan? plan,
  OrganizationWorkspaceDraft draft,
) {
  if (plan == null) return const [];
  final itemsById = {for (final item in draft.items) item.id: item};
  final count = math.min(plan.itemIds.length, plan.itemStatuses.length);
  final result = <OrganizationWorkspaceItem>[];
  for (var index = 0; index < count; index++) {
    if (plan.itemStatuses[index] != 'error') continue;
    final item = itemsById[plan.itemIds[index]];
    if (item != null) result.add(item);
  }
  return result;
}

int _organizationFolderItemErrorCount(
  OrganizationPlan? plan,
  OrganizationWorkspaceDraft draft,
  String? folderId,
) {
  if (plan == null) return 0;
  final itemsById = {for (final item in draft.items) item.id: item};
  final count = math.min(plan.itemIds.length, plan.itemStatuses.length);
  var result = 0;
  for (var index = 0; index < count; index++) {
    if (plan.itemStatuses[index] != 'error') continue;
    final item = itemsById[plan.itemIds[index]];
    if (item?.destinationFolderId == folderId) result++;
  }
  return result;
}

Map<OrganizationCategory, List<String>> _unassignedCategoryItemIds(
  OrganizationPlan plan,
  OrganizationWorkspaceDraft draft,
) {
  final result = <OrganizationCategory, List<String>>{
    for (final category in OrganizationCategory.values) category: <String>[],
  };
  final itemsById = {for (final item in draft.items) item.id: item};
  final count = math.min(plan.itemIds.length, plan.itemCategories.length);
  for (var index = 0; index < count; index++) {
    final item = itemsById[plan.itemIds[index]];
    if (item == null || item.destinationFolderId != null) continue;
    final category = OrganizationCategory.fromWireName(
      plan.itemCategories[index],
    );
    if (category != null) result[category]!.add(item.id);
  }
  return result;
}

Map<OrganizationCategory, int> _unassignedCategoryCounts(
  OrganizationPlan? plan,
  OrganizationWorkspaceDraft draft,
) {
  if (plan == null) {
    return {for (final category in OrganizationCategory.values) category: 0};
  }
  return {
    for (final entry in _unassignedCategoryItemIds(plan, draft).entries)
      entry.key: entry.value.length,
  };
}

IconData _organizationCategoryIcon(OrganizationCategory category) {
  return switch (category) {
    OrganizationCategory.image => Icons.image_outlined,
    OrganizationCategory.video => Icons.movie_outlined,
    OrganizationCategory.audio => Icons.audio_file_outlined,
    OrganizationCategory.document => Icons.description_outlined,
    OrganizationCategory.archive => Icons.archive_outlined,
    OrganizationCategory.other => Icons.more_horiz_rounded,
  };
}

Color _organizationCategoryColor(OrganizationCategory category) {
  return switch (category) {
    OrganizationCategory.image => primaryBright,
    OrganizationCategory.video => danger,
    OrganizationCategory.audio => mint,
    OrganizationCategory.document => const Color(0xFF60A5FA),
    OrganizationCategory.archive => warning,
    OrganizationCategory.other => muted,
  };
}

String _localizedOrganizationCategoryReason(
  OrganizationCategory category,
  String? reason,
) {
  final label = category.folderName;
  if (reason == null || reason == 'unknown') {
    return '沒有找到明確特徵，歸入「$label」供你確認';
  }
  if (reason == 'unreadable') {
    return '無法讀取內容特徵，歸入「$label」供你確認';
  }
  const combinedPrefix = 'content+extension:';
  if (reason.startsWith(combinedPrefix)) {
    final details = reason.substring(combinedPrefix.length).split(':');
    final extension = details.isEmpty ? '' : details.last;
    return '由檔案內容與 $extension 副檔名判斷為「$label」';
  }
  const contentPrefix = 'content:';
  if (reason.startsWith(contentPrefix)) {
    return '由檔案內容特徵（${reason.substring(contentPrefix.length)}）判斷為「$label」';
  }
  const extensionPrefix = 'extension:';
  if (reason.startsWith(extensionPrefix)) {
    return '由 ${reason.substring(extensionPrefix.length)} 副檔名判斷為「$label」';
  }
  return 'Flick 判斷此檔案屬於「$label」';
}

String _friendlyOrganizationError(Object error) {
  if (error is RpcException) {
    return switch (error.code) {
      'invalid_organization' => '整理計畫資料不一致，請重新加入檔案後再試',
      'invalid_collision_strategy' => '不支援這個衝突處理方式，請重新選擇',
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
