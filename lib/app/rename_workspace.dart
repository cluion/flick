import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bridra_flutter/bridra_flutter.dart' show RpcException;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/backend_gateway.dart';
import '../domain/collision_strategy.dart';
import '../domain/directory_import_options.dart';
import '../domain/file_list_io.dart';
import '../domain/preview_list_options.dart';
import '../domain/rename_list_io.dart';
import '../domain/rule_configuration_history.dart';
import '../domain/rename_rule.dart';
import '../domain/rule_preset.dart';
import '../domain/rule_recipe_file.dart';
import '../platform/file_actions.dart';
import 'flick_app.dart';
import 'organize_workspace.dart';

const _savedRulesKey = 'flick.rename-rules.v2';
const _savedRulePresetsKey = 'flick.rule-presets.v1';
const _savedRuleHistoryKey = 'flick.rule-history.v1';
const _savedCollisionStrategyKey = 'flick.collision-strategy.v1';
const _maxRulePresetFileBytes = 5 * 1024 * 1024;
const _maxRuleRecipeFileBytes = 1024 * 1024;
const _maxRenameItems = 10000;
const _previewRowExtent = 65.0;

enum _WorkspaceMode { rename, organize }

class RenameWorkspace extends StatefulWidget {
  const RenameWorkspace({
    super.key,
    required this.connector,
    required this.versionLoader,
    required this.revealFile,
    required this.copyPath,
  });

  final BackendConnector connector;
  final AppVersionLoader versionLoader;
  final FilePathAction revealFile;
  final FilePathAction copyPath;

  @override
  State<RenameWorkspace> createState() => _RenameWorkspaceState();
}

class _RenameWorkspaceState extends State<RenameWorkspace> {
  BackendGateway? _backend;
  HealthInfo? _health;
  RenamePlan? _plan;
  RenameHistory? _history;
  String? _appVersion;
  List<String> _paths = const [];
  final Set<String> _excludedPaths = {};
  final Map<String, String> _nameOverrides = {};
  final Set<String> _selectedPaths = {};
  final FocusNode _previewFocusNode = FocusNode(
    debugLabel: 'Flick preview list',
  );
  final ScrollController _previewScrollController = ScrollController();
  final TextEditingController _previewSearchController =
      TextEditingController();
  List<RenameRule> _rules = [RenameRule.create(RenameRuleType.newName)];
  List<RulePreset> _rulePresets = const [];
  List<RuleConfigurationSnapshot> _ruleHistory = const [];
  CollisionStrategy _collisionStrategy = CollisionStrategy.fail;
  Future<void> _rulePresetSaveQueue = Future.value();
  Future<void> _ruleHistorySaveQueue = Future.value();
  Timer? _previewTimer;
  Timer? _ruleHistoryTimer;
  Object? _error;
  String? _notice;
  var _connecting = true;
  var _previewing = false;
  var _previewPending = false;
  var _previewFailed = false;
  var _scanning = false;
  var _applying = false;
  var _dragging = false;
  var _workspaceMode = _WorkspaceMode.rename;
  var _previewGeneration = 0;
  String? _activePath;
  int? _selectionAnchorIndex;
  String _previewQuery = '';
  PreviewSortField _previewSortField = PreviewSortField.addedOrder;
  var _previewSortAscending = true;
  List<int>? _visiblePreviewIndicesCache;

  @override
  void initState() {
    super.initState();
    unawaited(_loadAppVersion());
    unawaited(_bootstrap());
  }

  Future<void> _loadAppVersion() async {
    try {
      final version = await widget.versionLoader();
      if (mounted) setState(() => _appVersion = version);
    } on Object {
      // Version metadata is informative and must never block the workspace
    }
  }

  Future<void> _bootstrap() async {
    await _restoreRulePreferences();
    BackendGateway? backend;
    try {
      backend = await widget.connector();
      final health = await backend.health();
      final history = await backend.renameHistory();
      if (!mounted) {
        await backend.close();
        return;
      }
      setState(() {
        _backend = backend;
        _health = health;
        _history = history;
      });
    } on Object catch (error) {
      await backend?.close();
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _connecting = false);
    }
  }

  Future<void> _restoreRulePreferences() async {
    late final SharedPreferencesAsync preferences;
    try {
      preferences = SharedPreferencesAsync();
    } on Object {
      return;
    }

    List<RenameRule>? rules;
    List<RulePreset>? presets;
    List<RuleConfigurationSnapshot>? ruleHistory;
    CollisionStrategy? collisionStrategy;
    try {
      final saved = await preferences.getString(_savedRulesKey);
      if (saved != null) rules = decodeSavedRules(saved);
    } on Object {
      // A damaged current-rule snapshot must not block saved presets.
    }
    try {
      final saved = await preferences.getString(_savedRulePresetsKey);
      if (saved != null) presets = decodeRulePresets(saved);
    } on Object {
      // A damaged preset snapshot must not block current-rule restoration.
    }
    try {
      final saved = await preferences.getString(_savedRuleHistoryKey);
      if (saved != null) {
        ruleHistory = decodeRuleConfigurationHistory(saved);
      }
    } on Object {
      // A damaged rule-history snapshot must not block other preferences.
    }
    try {
      collisionStrategy = CollisionStrategy.fromWireName(
        await preferences.getString(_savedCollisionStrategyKey),
      );
    } on Object {
      // Collision handling safely falls back to blocking conflicts.
    }
    if (!mounted) return;
    setState(() {
      if (rules != null && rules.isNotEmpty) _rules = rules;
      if (presets != null) _rulePresets = presets;
      if (ruleHistory case final history?) _ruleHistory = history;
      if (collisionStrategy case final strategy?) {
        _collisionStrategy = strategy;
      }
    });
  }

  Future<void> _saveRules() async {
    try {
      final preferences = SharedPreferencesAsync();
      await preferences.setString(_savedRulesKey, encodeSavedRules(_rules));
    } on Object {
      // Preview and rename remain available if preference storage is unavailable.
    }
  }

  Future<void> _saveCollisionStrategy() async {
    try {
      final preferences = SharedPreferencesAsync();
      await preferences.setString(
        _savedCollisionStrategyKey,
        _collisionStrategy.wireName,
      );
    } on Object {
      // Renaming remains available if preference storage is unavailable.
    }
  }

  Future<void> _saveRulePresets() async {
    final encoded = encodeRulePresets(_rulePresets);
    _rulePresetSaveQueue = _rulePresetSaveQueue.then((_) async {
      try {
        final preferences = SharedPreferencesAsync();
        await preferences.setString(_savedRulePresetsKey, encoded);
      } on Object {
        // Rule editing remains available if preference storage is unavailable.
      }
    });
    await _rulePresetSaveQueue;
  }

  Future<void> _saveRuleHistory() async {
    final encoded = encodeRuleConfigurationHistory(_ruleHistory);
    _ruleHistorySaveQueue = _ruleHistorySaveQueue.then((_) async {
      try {
        final preferences = SharedPreferencesAsync();
        await preferences.setString(_savedRuleHistoryKey, encoded);
      } on Object {
        // Rule editing remains available if preference storage is unavailable.
      }
    });
    await _ruleHistorySaveQueue;
  }

  Future<void> _chooseFiles() async {
    try {
      final files = await openFiles();
      _addPaths(files.map((file) => file.path));
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _revealPath(String path) async {
    try {
      await widget.revealFile(path);
      if (!mounted) return;
      setState(() {
        _notice = '已開啟 ${_fileNameFromPath(path)} 的所在位置';
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _copyPath(String path) async {
    try {
      await widget.copyPath(path);
      if (!mounted) return;
      setState(() {
        _notice = '已複製完整路徑：$path';
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _saveFileList() async {
    if (_paths.isEmpty) return;
    final paths = List<String>.of(_paths);
    final excludedPaths = Set<String>.of(_excludedPaths);
    final nameOverrides = Map<String, String>.of(_nameOverrides);
    try {
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Flick 檔案清單', extensions: ['flicklist']),
        ],
        suggestedName: 'flick-files.flicklist',
        confirmButtonText: '儲存清單',
      );
      if (location == null || !mounted) return;
      final outputPath = location.path.toLowerCase().endsWith('.flicklist')
          ? location.path
          : '${location.path}.flicklist';
      await File(outputPath).writeAsString(
        encodeFlickFileList(
          paths: paths,
          excludedPaths: excludedPaths,
          nameOverrides: nameOverrides,
        ),
        flush: true,
      );
      if (!mounted) return;
      setState(() {
        _notice = '已將 ${paths.length} 個檔案儲存到 ${_fileNameFromPath(outputPath)}';
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _loadFileList() async {
    var loading = false;
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Flick 檔案清單', extensions: ['flicklist']),
        ],
        confirmButtonText: '載入清單',
      );
      if (file == null || !mounted) return;
      final document = decodeFlickFileList(await file.readAsString());
      if (document.items.isEmpty) {
        throw const FormatException('檔案清單沒有任何項目');
      }
      if (document.items.length > _maxRenameItems) {
        throw FormatException('檔案清單超過 $_maxRenameItems 個項目的上限');
      }

      setState(() {
        _scanning = true;
        _error = null;
        _notice = null;
      });
      loading = true;
      final availableItems = <FlickFileListItem>[];
      var unavailableCount = 0;
      for (final item in document.items) {
        try {
          final type = await FileSystemEntity.type(
            item.path,
            followLinks: false,
          );
          if (type == FileSystemEntityType.file) {
            availableItems.add(item);
          } else {
            unavailableCount++;
          }
        } on Object {
          unavailableCount++;
        }
      }
      if (!mounted) return;
      if (availableItems.isEmpty) {
        throw const FormatException('清單中的檔案都已不存在或無法讀取');
      }

      if (_paths.isNotEmpty) {
        final replace = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: surfaceRaised,
            title: const Text('取代目前的檔案清單？'),
            content: Text(
              '載入 ${availableItems.length} 個檔案會取代目前的 ${_paths.length} 個檔案；改名規則不會變更。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('載入並取代'),
              ),
            ],
          ),
        );
        if (replace != true || !mounted) return;
      }

      _previewGeneration++;
      _previewTimer?.cancel();
      _previewSearchController.clear();
      setState(() {
        _paths = List.unmodifiable(availableItems.map((item) => item.path));
        _excludedPaths
          ..clear()
          ..addAll(
            availableItems
                .where((item) => !item.included)
                .map((item) => item.path),
          );
        _nameOverrides
          ..clear()
          ..addEntries(
            availableItems
                .where((item) => item.overrideName != null)
                .map((item) => MapEntry(item.path, item.overrideName!)),
          );
        _selectedPaths.clear();
        _activePath = null;
        _selectionAnchorIndex = null;
        _previewQuery = '';
        _previewSortField = PreviewSortField.addedOrder;
        _previewSortAscending = true;
        _visiblePreviewIndicesCache = null;
        _plan = null;
        _previewFailed = false;
        _previewPending = false;
        _notice =
            '已從 ${_fileNameFromPath(file.path)} 載入 ${availableItems.length} 個檔案'
            '${unavailableCount == 0 ? '' : '，略過 $unavailableCount 個無法使用的項目'}';
        _error = null;
      });
      _schedulePreview(immediate: true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (loading && mounted) setState(() => _scanning = false);
    }
  }

  Future<void> _loadListRule(int index) async {
    if (index < 0 || index >= _rules.length) return;
    final ruleID = _rules[index].id;
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: '名稱清單', extensions: ['txt', 'csv']),
        ],
        confirmButtonText: '載入名稱',
      );
      if (file == null || !mounted) return;
      final fileName = _fileNameFromPath(file.path);
      final isCsv = fileName.toLowerCase().endsWith('.csv');
      final values = decodeRenameListFile(
        content: await file.readAsString(),
        csv: isCsv,
      );
      if (values.isEmpty) throw const FormatException('清單檔案沒有可用名稱');
      final currentIndex = _rules.indexWhere((rule) => rule.id == ruleID);
      if (currentIndex < 0 || !mounted) return;
      _updateRule(
        currentIndex,
        _rules[currentIndex].copyWith(
          values: values,
          target: isCsv ? RenameRuleTarget.both : null,
        ),
      );
      setState(() {
        _notice =
            '已從 $fileName 載入 ${values.length} 個名稱'
            '${isCsv ? '，套用到主檔名與副檔名' : ''}';
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _exportRenameMapping() async {
    final plan = _plan;
    if (plan == null || !listEquals(plan.sourcePaths, _paths)) return;
    try {
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'CSV 對照表', extensions: ['csv']),
        ],
        suggestedName: 'flick-rename-mapping.csv',
        confirmButtonText: '匯出對照表',
      );
      if (location == null || !mounted) return;
      final content = encodeRenameMappingCsv(
        originalNames: plan.originalNames,
        proposedNames: plan.proposedNames,
      );
      await File(location.path).writeAsString(content, flush: true);
      if (!mounted) return;
      setState(() {
        _notice = '已匯出 ${plan.originalNames.length} 筆名稱對照';
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _chooseDirectory() async {
    try {
      final directory = await getDirectoryPath(
        confirmButtonText: '加入資料夾',
        canCreateDirectories: false,
      );
      if (directory != null && mounted) {
        await _configureAndScanDirectories([directory]);
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _handleDroppedItems(List<XFile> items) async {
    final files = <String>[];
    final directories = <String>[];
    var unsupportedCount = 0;
    try {
      for (final item in items) {
        final type = await FileSystemEntity.type(item.path, followLinks: false);
        switch (type) {
          case FileSystemEntityType.file:
            files.add(item.path);
          case FileSystemEntityType.directory:
            directories.add(item.path);
          default:
            unsupportedCount++;
        }
      }
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
      return;
    }
    if (!mounted) return;
    if (files.isNotEmpty) {
      _addPaths(
        files,
        notice: unsupportedCount == 0 ? null : '已略過 $unsupportedCount 個不支援的項目',
      );
    } else if (unsupportedCount > 0) {
      setState(() => _notice = '已略過 $unsupportedCount 個不支援的項目');
    }
    if (directories.isNotEmpty && mounted) {
      await _configureAndScanDirectories(directories);
    }
  }

  Future<void> _configureAndScanDirectories(List<String> directories) async {
    final options = await showDialog<DirectoryImportOptions>(
      context: context,
      builder: (context) =>
          _DirectoryImportDialog(directoryCount: directories.length),
    );
    if (options == null || !mounted) return;
    final backend = _backend;
    if (backend == null) return;

    setState(() {
      _scanning = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await backend.scanDirectories(
        ScanDirectoriesRequest(
          directories: directories,
          recursive: options.recursive,
          patterns: options.patterns,
          includeHidden: options.includeHidden,
        ),
      );
      if (!mounted) return;
      final notice = result.paths.isEmpty
          ? '資料夾內沒有符合條件的檔案'
          : '掃描完成：找到 ${result.paths.length} 個檔案'
                '${result.skippedCount == 0 ? '' : '，略過 ${result.skippedCount} 個項目'}';
      _addPaths(result.paths, notice: notice);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  void _addPaths(Iterable<String> paths, {String? notice}) {
    final combined = <String>[..._paths];
    final known = combined.toSet();
    for (final path in paths) {
      if (path.isNotEmpty && known.add(path)) combined.add(path);
    }
    if (combined.length > _maxRenameItems) {
      setState(() {
        _error = '一次最多只能預覽 $_maxRenameItems 個檔案，請縮小資料夾範圍或使用檔案篩選';
      });
      return;
    }
    setState(() {
      _paths = List.unmodifiable(combined);
      _visiblePreviewIndicesCache = null;
      _notice = notice;
      _error = null;
    });
    _schedulePreview(immediate: true);
  }

  void _removePath(String path) {
    setState(() {
      _paths = _paths.where((candidate) => candidate != path).toList();
      _visiblePreviewIndicesCache = null;
      _excludedPaths.remove(path);
      _nameOverrides.remove(path);
      _selectedPaths.remove(path);
      if (_activePath == path) _activePath = null;
      _selectionAnchorIndex = null;
      _plan = null;
    });
    _schedulePreview(immediate: true);
  }

  void _clearPaths() {
    _previewGeneration++;
    _previewTimer?.cancel();
    setState(() {
      _paths = const [];
      _visiblePreviewIndicesCache = null;
      _excludedPaths.clear();
      _nameOverrides.clear();
      _selectedPaths.clear();
      _activePath = null;
      _selectionAnchorIndex = null;
      _plan = null;
      _error = null;
      _previewing = false;
      _previewPending = false;
      _previewFailed = false;
    });
  }

  void _setPathIncluded(String path, bool included) {
    _setPathsIncluded([path], included);
  }

  void _setPathsIncluded(Iterable<String> paths, bool included) {
    if (_applying || _scanning) return;
    final currentPaths = _paths.toSet();
    setState(() {
      for (final path in paths) {
        if (!currentPaths.contains(path)) continue;
        if (included) {
          _excludedPaths.remove(path);
        } else {
          _excludedPaths.add(path);
        }
      }
      _notice = null;
    });
    _schedulePreview();
  }

  void _setAllPathsIncluded(bool included) {
    _setPathsIncluded(_visiblePreviewPaths, included);
  }

  void _setSelectedPathsIncluded(bool included) {
    if (_selectedPaths.isEmpty) return;
    _setPathsIncluded(_selectedPaths, included);
  }

  void _selectPath(String path) {
    final visiblePaths = _visiblePreviewPaths;
    final index = visiblePaths.indexOf(path);
    if (index < 0) return;
    final keyboard = HardwareKeyboard.instance;
    final extend = keyboard.isShiftPressed;
    final toggle = keyboard.isMetaPressed || keyboard.isControlPressed;
    final anchor = _selectionAnchorIndex;
    setState(() {
      if (extend && anchor != null) {
        final start = math.min(anchor, index);
        final end = math.max(anchor, index);
        final range = visiblePaths.sublist(start, end + 1);
        if (!toggle) _selectedPaths.clear();
        _selectedPaths.addAll(range);
      } else if (toggle) {
        if (!_selectedPaths.remove(path)) _selectedPaths.add(path);
        _selectionAnchorIndex = index;
      } else {
        _selectedPaths
          ..clear()
          ..add(path);
        _selectionAnchorIndex = index;
      }
      _activePath = path;
    });
    _previewFocusNode.requestFocus();
  }

  void _clearPreviewSelection() {
    if (_selectedPaths.isEmpty && _activePath == null) return;
    setState(() {
      _selectedPaths.clear();
      _activePath = null;
      _selectionAnchorIndex = null;
    });
  }

  void _selectAllPreviewPaths() {
    final visiblePaths = _visiblePreviewPaths;
    if (visiblePaths.isEmpty) return;
    setState(() {
      _selectedPaths
        ..clear()
        ..addAll(visiblePaths);
      _activePath = visiblePaths.first;
      _selectionAnchorIndex = 0;
    });
  }

  List<PreviewListRecord> get _previewRecords {
    final plan = _plan;
    final hasCurrentPlan =
        plan != null &&
        listEquals(plan.sourcePaths, _paths) &&
        plan.originalNames.length == _paths.length &&
        plan.proposedNames.length == _paths.length &&
        plan.sizes.length == _paths.length &&
        plan.modifiedAt.length == _paths.length;
    return List.generate(_paths.length, (index) {
      final fallback = _fileNameFromPath(_paths[index]);
      return PreviewListRecord(
        sourceIndex: index,
        path: _paths[index],
        originalName: hasCurrentPlan ? plan.originalNames[index] : fallback,
        proposedName: hasCurrentPlan ? plan.proposedNames[index] : fallback,
        size: hasCurrentPlan ? plan.sizes[index] : 0,
        modifiedAt: hasCurrentPlan ? plan.modifiedAt[index] : 0,
      );
    }, growable: false);
  }

  List<int> get _visiblePreviewIndices {
    return _visiblePreviewIndicesCache ??= visiblePreviewIndices(
      records: _previewRecords,
      query: _previewQuery,
      sortField: _previewSortField,
      ascending: _previewSortAscending,
    );
  }

  List<String> get _visiblePreviewPaths => _visiblePreviewIndices
      .map((index) => _paths[index])
      .toList(growable: false);

  void _setPreviewQuery(String query) {
    final indices = visiblePreviewIndices(
      records: _previewRecords,
      query: query,
      sortField: _previewSortField,
      ascending: _previewSortAscending,
    );
    final visible = indices.map((index) => _paths[index]).toSet();
    setState(() {
      _previewQuery = query;
      _visiblePreviewIndicesCache = indices;
      _selectedPaths.removeWhere((path) => !visible.contains(path));
      if (_activePath != null && !visible.contains(_activePath)) {
        _activePath = null;
      }
      _selectionAnchorIndex = null;
    });
  }

  void _clearPreviewQuery() {
    _previewSearchController.clear();
    _setPreviewQuery('');
  }

  void _setPreviewSortField(PreviewSortField field) {
    setState(() {
      _previewSortField = field;
      _visiblePreviewIndicesCache = null;
      _selectionAnchorIndex = null;
    });
  }

  void _togglePreviewSortDirection() {
    setState(() {
      _previewSortAscending = !_previewSortAscending;
      _visiblePreviewIndicesCache = null;
      _selectionAnchorIndex = null;
    });
  }

  void _setCollisionStrategy(CollisionStrategy strategy) {
    if (strategy == _collisionStrategy) return;
    setState(() {
      _collisionStrategy = strategy;
      _notice = null;
    });
    unawaited(_saveCollisionStrategy());
    _schedulePreview(immediate: true);
  }

  bool get _processingOrderVisible =>
      _previewQuery.isEmpty &&
      _previewSortField == PreviewSortField.addedOrder &&
      _previewSortAscending;

  void _showProcessingOrder() {
    _previewSearchController.clear();
    setState(() {
      _previewQuery = '';
      _previewSortField = PreviewSortField.addedOrder;
      _previewSortAscending = true;
      _visiblePreviewIndicesCache = null;
      _selectionAnchorIndex = null;
    });
    _previewFocusNode.requestFocus();
  }

  void _moveSelectedPaths(PreviewOrderMove move) {
    if (!_processingOrderVisible || _selectedPaths.isEmpty) return;
    final reordered = moveSelectedPreviewPaths(
      paths: _paths,
      selectedPaths: _selectedPaths,
      move: move,
    );
    if (listEquals(reordered, _paths)) return;
    final activePath = _activePath;
    setState(() {
      _paths = reordered;
      _plan = null;
      _visiblePreviewIndicesCache = null;
      _selectionAnchorIndex = null;
      _previewFailed = false;
      _error = null;
    });
    _schedulePreview(immediate: true);
    if (activePath != null) {
      final index = reordered.indexOf(activePath);
      if (index >= 0) _ensurePreviewIndexVisible(index);
    }
    _previewFocusNode.requestFocus();
  }

  KeyEventResult _handlePreviewKey(FocusNode _, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final keyboard = HardwareKeyboard.instance;
    if (key == LogicalKeyboardKey.keyA &&
        (keyboard.isMetaPressed || keyboard.isControlPressed)) {
      _selectAllPreviewPaths();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      _clearPreviewSelection();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown) {
      _movePreviewSelection(
        key == LogicalKeyboardKey.arrowDown ? 1 : -1,
        extend: keyboard.isShiftPressed,
      );
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.space) {
      final targets = _selectedPaths.isEmpty
          ? [_activePath].whereType<String>()
          : _selectedPaths;
      if (targets.isEmpty) return KeyEventResult.ignored;
      final include = targets.every(_excludedPaths.contains);
      _setPathsIncluded(targets, include);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.f2 || key == LogicalKeyboardKey.enter) {
      _editActivePreviewPath();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _movePreviewSelection(int delta, {required bool extend}) {
    final visiblePaths = _visiblePreviewPaths;
    if (visiblePaths.isEmpty) return;
    final currentIndex = _activePath == null
        ? -1
        : visiblePaths.indexOf(_activePath!);
    final nextIndex = currentIndex < 0
        ? (delta > 0 ? 0 : visiblePaths.length - 1)
        : math.max(0, math.min(currentIndex + delta, visiblePaths.length - 1));
    setState(() {
      if (extend) {
        final anchor =
            _selectionAnchorIndex ??
            (currentIndex < 0 ? nextIndex : currentIndex);
        _selectionAnchorIndex = anchor;
        final start = math.min(anchor, nextIndex);
        final end = math.max(anchor, nextIndex);
        _selectedPaths
          ..clear()
          ..addAll(visiblePaths.sublist(start, end + 1));
      } else {
        _selectedPaths
          ..clear()
          ..add(visiblePaths[nextIndex]);
        _selectionAnchorIndex = nextIndex;
      }
      _activePath = visiblePaths[nextIndex];
    });
    _ensurePreviewIndexVisible(nextIndex);
  }

  void _ensurePreviewIndexVisible(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_previewScrollController.hasClients) return;
      final position = _previewScrollController.position;
      final itemStart = index * _previewRowExtent;
      final itemEnd = itemStart + _previewRowExtent;
      var target = position.pixels;
      if (itemStart < position.pixels) {
        target = itemStart;
      } else if (itemEnd > position.pixels + position.viewportDimension) {
        target = itemEnd - position.viewportDimension;
      }
      if (target == position.pixels) return;
      _previewScrollController.animateTo(
        target.clamp(position.minScrollExtent, position.maxScrollExtent),
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    });
  }

  void _editActivePreviewPath() {
    final path = _activePath;
    final plan = _plan;
    if (path == null || plan == null || _applying || _scanning) return;
    final index = _paths.indexOf(path);
    if (index < 0 || index >= plan.proposedNames.length) return;
    unawaited(_editProposedName(path, plan.proposedNames[index]));
  }

  Future<void> _editProposedName(String path, String proposedName) async {
    final result = await showDialog<_NameOverrideResult>(
      context: context,
      builder: (context) => _NameOverrideDialog(
        initialName: _nameOverrides[path] ?? proposedName,
        hasOverride: _nameOverrides.containsKey(path),
      ),
    );
    if (!mounted) return;
    if (result == null) {
      _previewFocusNode.requestFocus();
      return;
    }
    setState(() {
      if (result.clear) {
        _nameOverrides.remove(path);
      } else {
        _nameOverrides[path] = result.name!;
      }
      _notice = null;
    });
    _schedulePreview(immediate: true);
    _previewFocusNode.requestFocus();
  }

  Future<void> _saveRuleRecipeFile() async {
    try {
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Flick 規則配方', extensions: ['flickrecipe']),
        ],
        suggestedName: 'flick-rules.flickrecipe',
        confirmButtonText: '匯出配方',
      );
      if (location == null || !mounted) return;
      final outputPath = location.path.toLowerCase().endsWith('.flickrecipe')
          ? location.path
          : '${location.path}.flickrecipe';
      File(
        outputPath,
      ).writeAsStringSync(encodeRuleRecipeFile(_rules), flush: true);
      if (!mounted) return;
      setState(() {
        _notice = '已將目前規則匯出到 ${_fileNameFromPath(outputPath)}';
        _error = null;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _loadRuleRecipeFile() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Flick 規則配方', extensions: ['flickrecipe', 'json']),
        ],
        confirmButtonText: '載入配方',
      );
      if (file == null || !mounted) return;
      final input = File(file.path);
      if (input.lengthSync() > _maxRuleRecipeFileBytes) {
        throw const FormatException('規則配方檔案不可超過 1 MB');
      }
      var encoded = input.readAsStringSync();
      if (encoded.startsWith('\uFEFF')) encoded = encoded.substring(1);
      final recipe = decodeRuleRecipeFile(encoded);
      final replace = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          backgroundColor: surfaceRaised,
          title: const Text('取代目前的規則？'),
          content: Text(
            '載入 ${recipe.rules.length} 個規則會取代目前的 ${_rules.length} 個規則；你的命名預設不會變更。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              key: const ValueKey('confirm-load-rule-recipe'),
              onPressed: () => Navigator.pop(context, true),
              child: const Text('載入並取代'),
            ),
          ],
        ),
      );
      if (replace != true || !mounted) return;
      setState(() {
        _rules = recipe.rules;
        _notice =
            '已從 ${_fileNameFromPath(file.path)} 載入 ${recipe.rules.length} 個規則';
        _error = null;
      });
      unawaited(_saveRules());
      _schedulePreview(immediate: true);
      _scheduleRuleHistorySnapshot(immediate: true);
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    }
  }

  Future<void> _showRulePresets() async {
    await showDialog<void>(
      context: context,
      builder: (context) => _RulePresetManagerDialog(
        initialPresets: _rulePresets,
        initialRuleHistory: _ruleHistory,
        currentRules: _rules,
        onPresetsChanged: _replaceRulePresets,
        onApply: _applyRulePreset,
        onRuleHistoryChanged: _replaceRuleHistory,
        onApplyRecent: _applyRecentRuleConfiguration,
      ),
    );
  }

  void _replaceRulePresets(List<RulePreset> presets) {
    if (!mounted) return;
    setState(() => _rulePresets = List.unmodifiable(presets));
    unawaited(_saveRulePresets());
  }

  void _replaceRuleHistory(List<RuleConfigurationSnapshot> history) {
    if (!mounted) return;
    if (history.isEmpty) _ruleHistoryTimer?.cancel();
    setState(() => _ruleHistory = List.unmodifiable(history));
    unawaited(_saveRuleHistory());
  }

  void _applyRulePreset(RulePreset preset) {
    setState(() {
      _rules = preset.instantiateRules();
      _notice = '已套用規則預設「${preset.name}」';
      _error = null;
    });
    unawaited(_saveRules());
    _schedulePreview(immediate: true);
    _scheduleRuleHistorySnapshot(immediate: true);
  }

  void _applyRecentRuleConfiguration(RuleConfigurationSnapshot snapshot) {
    setState(() {
      _rules = snapshot.instantiateRules();
      _notice = '已套用最近的規則設定';
      _error = null;
    });
    unawaited(_saveRules());
    _schedulePreview(immediate: true);
    _scheduleRuleHistorySnapshot(immediate: true);
  }

  void _updateRule(int index, RenameRule rule) {
    final rules = [..._rules]..[index] = rule;
    setState(() {
      _rules = List.unmodifiable(rules);
      _notice = null;
    });
    unawaited(_saveRules());
    _schedulePreview();
    _scheduleRuleHistorySnapshot();
  }

  void _addRule(RenameRuleType type) {
    setState(() {
      _rules = [..._rules, RenameRule.create(type)];
    });
    unawaited(_saveRules());
    _schedulePreview();
    _scheduleRuleHistorySnapshot();
  }

  void _removeRule(int index) {
    setState(() {
      _rules = [..._rules]..removeAt(index);
    });
    unawaited(_saveRules());
    _schedulePreview();
    _scheduleRuleHistorySnapshot();
  }

  void _reorderRule(int oldIndex, int newIndex) {
    final rules = [..._rules];
    final rule = rules.removeAt(oldIndex);
    rules.insert(newIndex, rule);
    setState(() => _rules = List.unmodifiable(rules));
    unawaited(_saveRules());
    _schedulePreview();
    _scheduleRuleHistorySnapshot();
  }

  void _scheduleRuleHistorySnapshot({bool immediate = false}) {
    _ruleHistoryTimer?.cancel();
    if (immediate) {
      _recordRuleHistorySnapshot();
      return;
    }
    _ruleHistoryTimer = Timer(const Duration(seconds: 1), () {
      _ruleHistoryTimer = null;
      _recordRuleHistorySnapshot();
    });
  }

  void _recordRuleHistorySnapshot() {
    final updated = recordRecentRuleConfiguration(
      history: _ruleHistory,
      rules: _rules,
    );
    if (identical(updated, _ruleHistory)) return;
    setState(() => _ruleHistory = updated);
    unawaited(_saveRuleHistory());
  }

  void _schedulePreview({bool immediate = false}) {
    _previewTimer?.cancel();
    final generation = ++_previewGeneration;
    if (_paths.isEmpty || _backend == null) {
      if (mounted) {
        setState(() {
          _plan = null;
          _visiblePreviewIndicesCache = null;
          _previewing = false;
          _previewPending = false;
        });
      }
      return;
    }
    if (!_previewPending) setState(() => _previewPending = true);
    if (immediate) {
      unawaited(_preview(generation));
      return;
    }
    _previewTimer = Timer(const Duration(milliseconds: 220), () {
      _previewTimer = null;
      unawaited(_preview(generation));
    });
  }

  Future<void> _preview(int generation) async {
    if (!mounted || generation != _previewGeneration) return;
    final backend = _backend;
    if (backend == null || _paths.isEmpty) {
      if (mounted && generation == _previewGeneration) {
        setState(() {
          _previewing = false;
          _previewPending = false;
        });
      }
      return;
    }
    setState(() {
      _previewing = true;
      _previewFailed = false;
      _error = null;
    });
    try {
      final plan = await backend.previewRename(
        PreviewRenameRequest(
          paths: _paths,
          recipe: encodeRenameRecipe(_rules),
          collisionStrategy: _collisionStrategy.wireName,
          excludedPaths: _paths
              .where(_excludedPaths.contains)
              .toList(growable: false),
          overridePaths: _paths
              .where(_nameOverrides.containsKey)
              .toList(growable: false),
          overrideNames: _paths
              .where(_nameOverrides.containsKey)
              .map((path) => _nameOverrides[path]!)
              .toList(growable: false),
        ),
      );
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _plan = plan;
        _visiblePreviewIndicesCache = null;
        _previewFailed = false;
        final visible = _visiblePreviewPaths.toSet();
        _selectedPaths.removeWhere((path) => !visible.contains(path));
        if (_activePath != null && !visible.contains(_activePath)) {
          _activePath = null;
          _selectionAnchorIndex = null;
        }
      });
    } on Object catch (error) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _plan = null;
        _visiblePreviewIndicesCache = null;
        _previewFailed = true;
        _error = error;
      });
    } finally {
      if (mounted && generation == _previewGeneration) {
        setState(() {
          _previewing = false;
          _previewPending = false;
        });
      }
    }
  }

  Future<void> _apply() async {
    final backend = _backend;
    final plan = _plan;
    if (backend == null ||
        plan == null ||
        plan.errorCount > 0 ||
        plan.renameableCount == 0 ||
        _previewing ||
        _previewPending ||
        _applying) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceRaised,
        title: const Text('套用批次改名？'),
        content: Text(
          '將重新命名 ${plan.renameableCount} 個檔案。Flick 會保留批次紀錄，讓你可以安全復原。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('開始改名'),
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
    try {
      final result = await backend.applyRename(
        ApplyRenameRequest(planId: plan.planId),
      );
      final history = await backend.renameHistory();
      if (!mounted) return;
      setState(() {
        _history = history;
        _notice = '已安全重新命名 ${result.changedCount} 個檔案';
        _paths = const [];
        _visiblePreviewIndicesCache = null;
        _excludedPaths.clear();
        _nameOverrides.clear();
        _selectedPaths.clear();
        _activePath = null;
        _selectionAnchorIndex = null;
        _plan = null;
        _previewPending = false;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  Future<void> _undoLatest() async {
    final backend = _backend;
    final history = _history;
    if (backend == null || history == null || _applying) return;
    final index = history.undoable.indexWhere((undoable) => undoable);
    if (index < 0) return;
    setState(() {
      _applying = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await backend.undoRename(
        UndoRenameRequest(batchId: history.batchIds[index]),
      );
      final refreshed = await backend.renameHistory();
      if (!mounted) return;
      setState(() {
        _history = refreshed;
        _notice = '已復原 ${result.changedCount} 個檔案';
        _paths = const [];
        _visiblePreviewIndicesCache = null;
        _excludedPaths.clear();
        _nameOverrides.clear();
        _selectedPaths.clear();
        _activePath = null;
        _selectionAnchorIndex = null;
        _plan = null;
        _previewPending = false;
      });
    } on Object catch (error) {
      if (mounted) setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _applying = false);
    }
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _ruleHistoryTimer?.cancel();
    _previewFocusNode.dispose();
    _previewScrollController.dispose();
    _previewSearchController.dispose();
    if (_backend case final backend?) unawaited(backend.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final connected = _health?.status == 'ok';
    final canUndo = _history?.undoable.any((undoable) => undoable) ?? false;
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        body: SafeArea(
          child: Column(
            children: [
              _WorkspaceHeader(
                appVersion: _appVersion,
                health: _health,
                connected: connected,
                connecting: _connecting,
                mode: _workspaceMode,
                canUndo: canUndo && _workspaceMode == _WorkspaceMode.rename,
                busy: _applying || _scanning,
                onUndo: _undoLatest,
                onModeChanged: (mode) => setState(() => _workspaceMode = mode),
              ),
              if (_error != null)
                _MessageBar(
                  color: danger,
                  icon: Icons.error_outline_rounded,
                  message: _friendlyError(_error!),
                  onClose: () => setState(() => _error = null),
                )
              else if (_notice case final notice?)
                _MessageBar(
                  color: mint,
                  icon: Icons.check_circle_outline_rounded,
                  message: notice,
                  onClose: () => setState(() => _notice = null),
                ),
              Expanded(
                child: IndexedStack(
                  index: _workspaceMode.index,
                  children: [
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final rules = _RulesPanel(
                          rules: _rules,
                          presetCount: _rulePresets.length,
                          currentNames:
                              _plan != null &&
                                  listEquals(_plan!.sourcePaths, _paths)
                              ? _plan!.proposedNames
                              : _paths
                                    .map(_fileNameFromPath)
                                    .toList(growable: false),
                          enabled: connected && !_applying && !_scanning,
                          canExportMapping:
                              _plan != null &&
                              listEquals(_plan!.sourcePaths, _paths),
                          onAdd: _addRule,
                          onManagePresets: _showRulePresets,
                          onLoadRecipe: _loadRuleRecipeFile,
                          onSaveRecipe: _saveRuleRecipeFile,
                          onUpdate: _updateRule,
                          onLoadList: _loadListRule,
                          onExportMapping: _exportRenameMapping,
                          onRemove: _removeRule,
                          onReorder: _reorderRule,
                        );
                        final preview = _PreviewPanel(
                          paths: _paths,
                          plan: _plan,
                          visibleIndices: _visiblePreviewIndices,
                          searchController: _previewSearchController,
                          searchQuery: _previewQuery,
                          sortField: _previewSortField,
                          sortAscending: _previewSortAscending,
                          collisionStrategy: _collisionStrategy,
                          excludedPaths: _excludedPaths,
                          overridePaths: _nameOverrides.keys.toSet(),
                          selectedPaths: _selectedPaths,
                          activePath: _activePath,
                          connected: connected,
                          previewing: _previewing,
                          previewPending: _previewPending,
                          previewFailed: _previewFailed,
                          applying: _applying,
                          scanning: _scanning,
                          dragging: _dragging,
                          onChooseFiles: _chooseFiles,
                          onChooseDirectory: _chooseDirectory,
                          onSaveFileList: _saveFileList,
                          onLoadFileList: _loadFileList,
                          onRevealPath: _revealPath,
                          onCopyPath: _copyPath,
                          onRemovePath: _removePath,
                          onSetPathIncluded: _setPathIncluded,
                          onSetAllPathsIncluded: _setAllPathsIncluded,
                          onSetSelectedPathsIncluded: _setSelectedPathsIncluded,
                          onSelectPath: _selectPath,
                          onClearSelection: _clearPreviewSelection,
                          onSearchChanged: _setPreviewQuery,
                          onClearSearch: _clearPreviewQuery,
                          onSortFieldChanged: _setPreviewSortField,
                          onToggleSortDirection: _togglePreviewSortDirection,
                          onCollisionStrategyChanged: _setCollisionStrategy,
                          processingOrderVisible: _processingOrderVisible,
                          enabledOrderMoves: {
                            for (final move in PreviewOrderMove.values)
                              if (canMoveSelectedPreviewPaths(
                                paths: _paths,
                                selectedPaths: _selectedPaths,
                                move: move,
                              ))
                                move,
                          },
                          onShowProcessingOrder: _showProcessingOrder,
                          onMoveSelectedPaths: _moveSelectedPaths,
                          onEditProposedName: _editProposedName,
                          onClearPaths: _clearPaths,
                          onApply: _apply,
                          focusNode: _previewFocusNode,
                          scrollController: _previewScrollController,
                          onKeyEvent: _handlePreviewKey,
                          onDragEntered: () => setState(() => _dragging = true),
                          onDragExited: () => setState(() => _dragging = false),
                          onDrop: (files) {
                            setState(() => _dragging = false);
                            unawaited(_handleDroppedItems(files));
                          },
                        );
                        if (constraints.maxWidth >= 900) {
                          return Row(
                            children: [
                              SizedBox(width: 360, child: rules),
                              const VerticalDivider(width: 1),
                              Expanded(child: preview),
                            ],
                          );
                        }
                        return Column(
                          children: [
                            const TabBar(
                              tabs: [
                                Tab(text: '改名規則'),
                                Tab(text: '檔案預覽'),
                              ],
                            ),
                            Expanded(
                              child: TabBarView(children: [rules, preview]),
                            ),
                          ],
                        );
                      },
                    ),
                    OrganizeWorkspace(
                      paths: _paths,
                      enabled: connected && !_applying && !_scanning,
                      scanning: _scanning,
                      onChooseFiles: _chooseFiles,
                      onChooseDirectory: _chooseDirectory,
                      onRevealPath: _revealPath,
                      onCopyPath: _copyPath,
                      onDrop: (files) => unawaited(_handleDroppedItems(files)),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NameOverrideResult {
  const _NameOverrideResult.override(this.name) : clear = false;

  const _NameOverrideResult.clear() : name = null, clear = true;

  final String? name;
  final bool clear;
}

class _NameOverrideDialog extends StatefulWidget {
  const _NameOverrideDialog({
    required this.initialName,
    required this.hasOverride,
  });

  final String initialName;
  final bool hasOverride;

  @override
  State<_NameOverrideDialog> createState() => _NameOverrideDialogState();
}

class _NameOverrideDialogState extends State<_NameOverrideDialog> {
  late final TextEditingController _controller;

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
    Navigator.pop(context, _NameOverrideResult.override(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceRaised,
      title: const Text('修改這個檔名'),
      content: SizedBox(
        width: 460,
        child: TextField(
          key: const ValueKey('manual-name-field'),
          controller: _controller,
          autofocus: true,
          onSubmitted: (_) => _submit(),
          decoration: const InputDecoration(
            labelText: '新檔名',
            helperText: '請包含副檔名；儲存後仍會檢查重複與不安全字元',
          ),
        ),
      ),
      actions: [
        if (widget.hasOverride)
          TextButton(
            onPressed: () =>
                Navigator.pop(context, const _NameOverrideResult.clear()),
            child: const Text('恢復規則結果'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('套用到預覽')),
      ],
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.appVersion,
    required this.health,
    required this.connected,
    required this.connecting,
    required this.mode,
    required this.canUndo,
    required this.busy,
    required this.onUndo,
    required this.onModeChanged,
  });

  final String? appVersion;
  final HealthInfo? health;
  final bool connected;
  final bool connecting;
  final _WorkspaceMode mode;
  final bool canUndo;
  final bool busy;
  final VoidCallback onUndo;
  final ValueChanged<_WorkspaceMode> onModeChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 980;
          return Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: primary,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(
                  mode == _WorkspaceMode.rename
                      ? Icons.drive_file_rename_outline_rounded
                      : Icons.account_tree_outlined,
                  color: Colors.white,
                  size: 21,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Flick',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              if (!compact) ...[
                const SizedBox(width: 10),
                Text(
                  mode == _WorkspaceMode.rename ? '批次檔名整理' : '視覺檔案整理',
                  style: const TextStyle(color: subtle, fontSize: 13),
                ),
              ],
              if (appVersion case final version?) ...[
                const SizedBox(width: 9),
                _VersionBadge(version: version),
              ],
              const Spacer(),
              _WorkspaceModeSwitcher(
                mode: mode,
                enabled: !busy,
                onChanged: onModeChanged,
              ),
              const SizedBox(width: 12),
              _ConnectionStatus(
                health: health,
                connected: connected,
                connecting: connecting,
              ),
              SizedBox(width: compact ? 8 : 12),
              if (compact)
                IconButton.outlined(
                  onPressed: canUndo && !busy ? onUndo : null,
                  tooltip: '復原上一批',
                  icon: const Icon(Icons.undo_rounded, size: 18),
                )
              else
                OutlinedButton.icon(
                  onPressed: canUndo && !busy ? onUndo : null,
                  icon: const Icon(Icons.undo_rounded, size: 18),
                  label: const Text('復原上一批'),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _WorkspaceModeSwitcher extends StatelessWidget {
  const _WorkspaceModeSwitcher({
    required this.mode,
    required this.enabled,
    required this.onChanged,
  });

  final _WorkspaceMode mode;
  final bool enabled;
  final ValueChanged<_WorkspaceMode> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF0E1117),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _WorkspaceModeButton(
            key: const ValueKey('workspace-mode-rename'),
            label: '改名',
            icon: Icons.drive_file_rename_outline_rounded,
            selected: mode == _WorkspaceMode.rename,
            enabled: enabled,
            onTap: () => onChanged(_WorkspaceMode.rename),
          ),
          _WorkspaceModeButton(
            key: const ValueKey('workspace-mode-organize'),
            label: '整理',
            icon: Icons.account_tree_outlined,
            selected: mode == _WorkspaceMode.organize,
            enabled: enabled,
            onTap: () => onChanged(_WorkspaceMode.organize),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceModeButton extends StatelessWidget {
  const _WorkspaceModeButton({
    super.key,
    required this.label,
    required this.icon,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected ? primary.withValues(alpha: 0.18) : Colors.transparent,
      borderRadius: BorderRadius.circular(7),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(7),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 6),
          child: Row(
            children: [
              Icon(icon, color: selected ? primaryBright : subtle, size: 15),
              const SizedBox(width: 5),
              Text(
                label,
                style: TextStyle(
                  color: selected ? primaryBright : muted,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VersionBadge extends StatelessWidget {
  const _VersionBadge({required this.version});

  final String version;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: primary.withValues(alpha: 0.24)),
      ),
      child: Text(
        version,
        style: const TextStyle(
          color: primaryBright,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({
    required this.health,
    required this.connected,
    required this.connecting,
  });

  final HealthInfo? health;
  final bool connected;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final color = connected ? mint : (connecting ? warning : danger);
    final label = connected ? '本機引擎就緒' : (connecting ? '連線中' : '引擎離線');
    final details = health == null
        ? label
        : '${health!.runtime} · Bridra ${health!.frameworkVersion} · '
              'Protocol ${health!.protocolVersion}';
    return Tooltip(
      message: details,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 7),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBar extends StatelessWidget {
  const _MessageBar({
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
      width: double.infinity,
      color: color.withValues(alpha: 0.1),
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 9),
          Expanded(
            child: Text(
              message,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            onPressed: onClose,
            icon: const Icon(Icons.close_rounded, size: 18),
            color: color,
            tooltip: '關閉',
          ),
        ],
      ),
    );
  }
}

enum _RulePresetAction { rename, duplicate, export, delete }

class _RulePresetManagerDialog extends StatefulWidget {
  const _RulePresetManagerDialog({
    required this.initialPresets,
    required this.initialRuleHistory,
    required this.currentRules,
    required this.onPresetsChanged,
    required this.onApply,
    required this.onRuleHistoryChanged,
    required this.onApplyRecent,
  });

  final List<RulePreset> initialPresets;
  final List<RuleConfigurationSnapshot> initialRuleHistory;
  final List<RenameRule> currentRules;
  final ValueChanged<List<RulePreset>> onPresetsChanged;
  final ValueChanged<RulePreset> onApply;
  final ValueChanged<List<RuleConfigurationSnapshot>> onRuleHistoryChanged;
  final ValueChanged<RuleConfigurationSnapshot> onApplyRecent;

  @override
  State<_RulePresetManagerDialog> createState() =>
      _RulePresetManagerDialogState();
}

class _RulePresetManagerDialogState extends State<_RulePresetManagerDialog> {
  late List<RulePreset> _presets = List.of(widget.initialPresets);
  late List<RuleConfigurationSnapshot> _ruleHistory = List.of(
    widget.initialRuleHistory,
  );
  var _transferring = false;
  String? _transferError;
  String? _transferNotice;

  Set<String> _existingNames({String? exceptPresetId}) => {
    for (final preset in _presets)
      if (preset.id != exceptPresetId) preset.name.toLowerCase(),
  };

  Future<String?> _askForName({
    required String title,
    required String actionLabel,
    String initialName = '',
    String? exceptPresetId,
  }) {
    return showDialog<String>(
      context: context,
      builder: (context) => _RulePresetNameDialog(
        title: title,
        actionLabel: actionLabel,
        initialName: initialName,
        existingNames: _existingNames(exceptPresetId: exceptPresetId),
      ),
    );
  }

  void _replacePresets(List<RulePreset> presets) {
    final immutable = List<RulePreset>.unmodifiable(presets);
    setState(() {
      _presets = immutable;
      _transferError = null;
    });
    widget.onPresetsChanged(immutable);
  }

  Future<void> _saveCurrentRules() async {
    final name = await _askForName(title: '儲存規則預設', actionLabel: '儲存');
    if (name == null || !mounted) return;
    _replacePresets([
      ..._presets,
      RulePreset.create(name: name, rules: widget.currentRules),
    ]);
  }

  Future<void> _showStarterRulePresets() async {
    final starter = await showDialog<StarterRulePreset>(
      context: context,
      builder: (context) => const _StarterRulePresetDialog(),
    );
    if (starter == null || !mounted) return;
    if (_presets.length >= maxRulePresetCount) {
      setState(() => _transferError = '規則預設已達 1000 個的上限');
      return;
    }
    final name = _availablePresetName(starter.name);
    _replacePresets([
      ..._presets,
      RulePreset.create(name: name, rules: starter.rules),
    ]);
    setState(() => _transferNotice = '已將內建範本「$name」加入我的預設');
  }

  Future<void> _showRecentRuleConfigurations() async {
    final snapshot = await showDialog<RuleConfigurationSnapshot>(
      context: context,
      builder: (context) => _RecentRuleConfigurationsDialog(
        initialHistory: _ruleHistory,
        onHistoryChanged: (history) {
          _ruleHistory = List.unmodifiable(history);
          widget.onRuleHistoryChanged(_ruleHistory);
        },
      ),
    );
    if (snapshot == null || !mounted) return;
    widget.onApplyRecent(snapshot);
    Navigator.pop(context);
  }

  Future<void> _handleAction(
    RulePreset preset,
    _RulePresetAction action,
  ) async {
    switch (action) {
      case _RulePresetAction.rename:
        final name = await _askForName(
          title: '重新命名預設',
          actionLabel: '重新命名',
          initialName: preset.name,
          exceptPresetId: preset.id,
        );
        if (name == null || !mounted) return;
        _replacePresets([
          for (final item in _presets)
            if (item.id == preset.id) item.copyWith(name: name) else item,
        ]);
        return;
      case _RulePresetAction.duplicate:
        final name = await _askForName(
          title: '複製規則預設',
          actionLabel: '複製',
          initialName: _availableCopyName(preset.name),
        );
        if (name == null || !mounted) return;
        final index = _presets.indexWhere((item) => item.id == preset.id);
        final copy = RulePreset.create(name: name, rules: preset.rules);
        final presets = [..._presets]..insert(index + 1, copy);
        _replacePresets(presets);
        return;
      case _RulePresetAction.export:
        await _exportPresets([
          preset,
        ], suggestedName: '${rulePresetFileStem(preset.name)}.flickpreset');
        return;
      case _RulePresetAction.delete:
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            backgroundColor: surfaceRaised,
            title: const Text('刪除規則預設？'),
            content: Text('「${preset.name}」會從這台裝置永久刪除。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('取消'),
              ),
              FilledButton(
                key: const ValueKey('confirm-delete-rule-preset'),
                onPressed: () => Navigator.pop(context, true),
                child: const Text('刪除'),
              ),
            ],
          ),
        );
        if (confirmed != true || !mounted) return;
        _replacePresets([
          for (final item in _presets)
            if (item.id != preset.id) item,
        ]);
        return;
    }
  }

  Future<void> _importPresets() async {
    setState(() {
      _transferring = true;
      _transferError = null;
      _transferNotice = null;
    });
    try {
      final file = await openFile(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Flick 規則預設', extensions: ['flickpreset']),
        ],
        confirmButtonText: '匯入預設',
      );
      if (file == null || !mounted) return;
      if (await file.length() > _maxRulePresetFileBytes) {
        throw const FormatException('規則預設檔案不可超過 5 MB');
      }
      var encoded = await file.readAsString();
      if (encoded.startsWith('\uFEFF')) encoded = encoded.substring(1);
      final imported = decodeRulePresets(encoded);
      if (imported.isEmpty) {
        throw const FormatException('檔案中沒有可匯入的規則預設');
      }
      final merged = mergeImportedRulePresets(
        existing: _presets,
        imported: imported,
      );
      _replacePresets(merged);
      setState(() {
        _transferNotice =
            '已從 ${_fileNameFromPath(file.path)} 匯入 ${imported.length} 個預設';
      });
    } on Object catch (error) {
      if (mounted) setState(() => _transferError = _transferErrorText(error));
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  Future<void> _exportPresets(
    List<RulePreset> presets, {
    required String suggestedName,
  }) async {
    setState(() {
      _transferring = true;
      _transferError = null;
      _transferNotice = null;
    });
    try {
      final location = await getSaveLocation(
        acceptedTypeGroups: const [
          XTypeGroup(label: 'Flick 規則預設', extensions: ['flickpreset']),
        ],
        suggestedName: suggestedName,
        confirmButtonText: '匯出預設',
      );
      if (location == null || !mounted) return;
      final outputPath = location.path.toLowerCase().endsWith('.flickpreset')
          ? location.path
          : '${location.path}.flickpreset';
      await File(
        outputPath,
      ).writeAsString(encodeRulePresets(presets), flush: true);
      if (!mounted) return;
      setState(() {
        _transferNotice =
            '已將 ${presets.length} 個預設匯出到 ${_fileNameFromPath(outputPath)}';
      });
    } on Object catch (error) {
      if (mounted) setState(() => _transferError = _transferErrorText(error));
    } finally {
      if (mounted) setState(() => _transferring = false);
    }
  }

  String _transferErrorText(Object error) {
    if (error case FormatException(:final message)) return message;
    return error.toString();
  }

  String _availableCopyName(String name) {
    final existing = _existingNames();
    final base = '$name 複本';
    if (!existing.contains(base.toLowerCase())) return base;
    var suffix = 2;
    while (existing.contains('$base $suffix'.toLowerCase())) {
      suffix++;
    }
    return '$base $suffix';
  }

  String _availablePresetName(String name) {
    final existing = _existingNames();
    if (!existing.contains(name.toLowerCase())) return name;
    var suffix = 2;
    while (existing.contains('$name $suffix'.toLowerCase())) {
      suffix++;
    }
    return '$name $suffix';
  }

  void _apply(RulePreset preset) {
    widget.onApply(preset);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final maxListHeight = math.min(
      300.0,
      MediaQuery.sizeOf(context).height * 0.38,
    );
    return AlertDialog(
      backgroundColor: surfaceRaised,
      title: const Text('規則預設'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '儲存常用的規則組合，之後可一鍵套用。上次使用的規則仍會另外自動還原。',
              style: TextStyle(color: subtle, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton.icon(
                  key: const ValueKey('save-current-rule-preset'),
                  onPressed: _transferring ? null : _saveCurrentRules,
                  icon: const Icon(Icons.bookmark_add_outlined, size: 18),
                  label: const Text('儲存目前規則'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('import-rule-presets'),
                  onPressed: _transferring ? null : _importPresets,
                  icon: const Icon(Icons.file_download_outlined, size: 18),
                  label: const Text('匯入'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('starter-rule-presets'),
                  onPressed: _transferring ? null : _showStarterRulePresets,
                  icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                  label: const Text('內建範本'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('recent-rule-configurations'),
                  onPressed: _transferring
                      ? null
                      : _showRecentRuleConfigurations,
                  icon: const Icon(Icons.history_rounded, size: 18),
                  label: const Text('最近使用'),
                ),
                OutlinedButton.icon(
                  key: const ValueKey('export-all-rule-presets'),
                  onPressed: _transferring || _presets.isEmpty
                      ? null
                      : () => _exportPresets(
                          _presets,
                          suggestedName: 'flick-presets.flickpreset',
                        ),
                  icon: const Icon(Icons.file_upload_outlined, size: 18),
                  label: const Text('全部匯出'),
                ),
              ],
            ),
            if (_transferError case final message?) ...[
              const SizedBox(height: 10),
              Text(
                message,
                key: const ValueKey('rule-preset-transfer-error'),
                style: const TextStyle(color: danger, fontSize: 12),
              ),
            ] else if (_transferNotice case final message?) ...[
              const SizedBox(height: 10),
              Text(
                message,
                key: const ValueKey('rule-preset-transfer-notice'),
                style: const TextStyle(color: mint, fontSize: 12),
              ),
            ],
            const SizedBox(height: 14),
            const Divider(height: 1),
            if (_presets.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 34),
                child: Column(
                  children: [
                    Icon(Icons.bookmarks_outlined, color: subtle, size: 34),
                    SizedBox(height: 10),
                    Text('尚未建立規則預設', style: TextStyle(color: subtle)),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxListHeight),
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.only(top: 10),
                  itemCount: _presets.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 7),
                  itemBuilder: (context, index) {
                    final preset = _presets[index];
                    return Container(
                      key: ValueKey('rule-preset-${preset.id}'),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: border),
                      ),
                      padding: const EdgeInsets.fromLTRB(13, 8, 5, 8),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.bookmark_outline_rounded,
                            color: primaryBright,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  preset.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  '${preset.rules.length} 個規則',
                                  style: const TextStyle(
                                    color: subtle,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          TextButton(
                            key: ValueKey('apply-rule-preset-${preset.id}'),
                            onPressed: _transferring
                                ? null
                                : () => _apply(preset),
                            child: const Text('套用'),
                          ),
                          PopupMenuButton<_RulePresetAction>(
                            key: ValueKey('rule-preset-actions-${preset.id}'),
                            enabled: !_transferring,
                            tooltip: '預設選項',
                            onSelected: (action) =>
                                _handleAction(preset, action),
                            itemBuilder: (context) => const [
                              PopupMenuItem(
                                value: _RulePresetAction.rename,
                                child: Text('重新命名'),
                              ),
                              PopupMenuItem(
                                value: _RulePresetAction.duplicate,
                                child: Text('複製預設'),
                              ),
                              PopupMenuItem(
                                value: _RulePresetAction.export,
                                child: Text('匯出預設'),
                              ),
                              PopupMenuDivider(),
                              PopupMenuItem(
                                value: _RulePresetAction.delete,
                                child: Text('刪除預設'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

class _RecentRuleConfigurationsDialog extends StatefulWidget {
  const _RecentRuleConfigurationsDialog({
    required this.initialHistory,
    required this.onHistoryChanged,
  });

  final List<RuleConfigurationSnapshot> initialHistory;
  final ValueChanged<List<RuleConfigurationSnapshot>> onHistoryChanged;

  @override
  State<_RecentRuleConfigurationsDialog> createState() =>
      _RecentRuleConfigurationsDialogState();
}

class _RecentRuleConfigurationsDialogState
    extends State<_RecentRuleConfigurationsDialog> {
  late List<RuleConfigurationSnapshot> _history = List.of(
    widget.initialHistory,
  );

  Future<void> _clearHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: surfaceRaised,
        title: const Text('清除最近規則設定？'),
        content: const Text('只會清除規則設定快照，不會影響預設或檔案改名復原紀錄。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const ValueKey('confirm-clear-rule-history'),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('清除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _history = const []);
    widget.onHistoryChanged(const []);
  }

  @override
  Widget build(BuildContext context) {
    final maxListHeight = math.min(
      380.0,
      MediaQuery.sizeOf(context).height * 0.52,
    );
    return AlertDialog(
      backgroundColor: surfaceRaised,
      title: const Text('最近使用的規則'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '停止編輯約 1 秒後自動記錄；相同設定會去重，最多保留 20 筆。這裡不包含檔案改名復原紀錄。',
              style: TextStyle(color: subtle, fontSize: 13),
            ),
            const SizedBox(height: 14),
            if (_history.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 34),
                child: Column(
                  children: [
                    Icon(Icons.history_rounded, color: subtle, size: 34),
                    SizedBox(height: 10),
                    Text('尚無最近規則設定', style: TextStyle(color: subtle)),
                  ],
                ),
              )
            else
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxListHeight),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _history.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final snapshot = _history[index];
                    return Container(
                      key: ValueKey('recent-rule-configuration-${snapshot.id}'),
                      decoration: BoxDecoration(
                        color: surface,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: border),
                      ),
                      padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.history_rounded,
                            color: primaryBright,
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _ruleConfigurationDescription(snapshot.rules),
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${snapshot.rules.length} 個規則 · ${_formatRuleHistoryTime(snapshot.savedAt)}',
                                  style: const TextStyle(
                                    color: subtle,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          TextButton(
                            key: ValueKey(
                              'apply-recent-rule-configuration-${snapshot.id}',
                            ),
                            onPressed: () => Navigator.pop(context, snapshot),
                            child: const Text('套用'),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('clear-rule-history'),
          onPressed: _history.isEmpty ? null : _clearHistory,
          child: const Text('清除記錄'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('完成'),
        ),
      ],
    );
  }
}

String _ruleConfigurationDescription(List<RenameRule> rules) {
  final descriptions = rules.take(3).map(_renameRuleDescription).toList();
  if (rules.length > descriptions.length) descriptions.add('…');
  return descriptions.join(' → ');
}

String _renameRuleDescription(RenameRule rule) {
  return switch (rule.type) {
    RenameRuleType.newName => '設定新檔名：${rule.value}',
    RenameRuleType.list => '名稱清單：${rule.values.length} 個名稱',
    RenameRuleType.replace =>
      rule.replacement.isEmpty
          ? '刪除文字：${rule.value}'
          : '取代：${rule.value} → ${rule.replacement}',
    RenameRuleType.prefix => '前綴：${rule.value}',
    RenameRuleType.suffix => '後綴：${rule.value}',
    RenameRuleType.letterCase =>
      '${rule.target.label}${switch (rule.mode) {
        'upper' => '轉大寫',
        'title' => '轉標題格式',
        _ => '轉小寫',
      }}',
    RenameRuleType.sequence =>
      '流水號：${rule.start.toString().padLeft(rule.padding, '0')} 起',
    RenameRuleType.trim => '清除${rule.target.label}頭尾空白',
  };
}

String _formatRuleHistoryTime(DateTime savedAt) {
  final local = savedAt.toLocal();
  String twoDigits(int value) => value.toString().padLeft(2, '0');
  return '${local.year}/${twoDigits(local.month)}/${twoDigits(local.day)} '
      '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
}

class _StarterRulePresetDialog extends StatelessWidget {
  const _StarterRulePresetDialog();

  @override
  Widget build(BuildContext context) {
    final maxListHeight = math.min(
      380.0,
      MediaQuery.sizeOf(context).height * 0.52,
    );
    return AlertDialog(
      backgroundColor: surfaceRaised,
      title: const Text('內建安全範本'),
      content: SizedBox(
        width: 500,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '範本只會在你選擇後加入「我的預設」，不會自動修改檔案。',
              style: TextStyle(color: subtle, fontSize: 13),
            ),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxListHeight),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: starterRulePresets.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final starter = starterRulePresets[index];
                  return Container(
                    decoration: BoxDecoration(
                      color: surface,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: border),
                    ),
                    padding: const EdgeInsets.fromLTRB(13, 10, 8, 10),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.auto_awesome_outlined,
                          color: primaryBright,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                starter.name,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                starter.description,
                                style: const TextStyle(
                                  color: subtle,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          key: ValueKey(
                            'add-starter-rule-preset-${starter.id}',
                          ),
                          onPressed: () => Navigator.pop(context, starter),
                          child: const Text('加入'),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
      ],
    );
  }
}

class _RulePresetNameDialog extends StatefulWidget {
  const _RulePresetNameDialog({
    required this.title,
    required this.actionLabel,
    required this.initialName,
    required this.existingNames,
  });

  final String title;
  final String actionLabel;
  final String initialName;
  final Set<String> existingNames;

  @override
  State<_RulePresetNameDialog> createState() => _RulePresetNameDialogState();
}

class _RulePresetNameDialogState extends State<_RulePresetNameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialName,
  );
  String? _errorText;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    final error = switch (name) {
      '' => '請輸入預設名稱',
      _ when name.length > 80 => '預設名稱不可超過 80 個字元',
      _ when widget.existingNames.contains(name.toLowerCase()) => '已有相同名稱的預設',
      _ => null,
    };
    if (error != null) {
      setState(() => _errorText = error);
      return;
    }
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceRaised,
      title: Text(widget.title),
      content: SizedBox(
        width: 380,
        child: TextField(
          key: const ValueKey('rule-preset-name-field'),
          controller: _controller,
          autofocus: true,
          maxLength: 80,
          decoration: InputDecoration(
            labelText: '預設名稱',
            hintText: '例如：照片日期與流水號',
            errorText: _errorText,
          ),
          textInputAction: TextInputAction.done,
          onChanged: (_) {
            if (_errorText != null) setState(() => _errorText = null);
          },
          onSubmitted: (_) => _submit(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const ValueKey('confirm-rule-preset-name'),
          onPressed: _submit,
          child: Text(widget.actionLabel),
        ),
      ],
    );
  }
}

enum _RuleRecipeFileAction { load, save }

class _RulesPanel extends StatelessWidget {
  const _RulesPanel({
    required this.rules,
    required this.presetCount,
    required this.currentNames,
    required this.enabled,
    required this.canExportMapping,
    required this.onAdd,
    required this.onManagePresets,
    required this.onLoadRecipe,
    required this.onSaveRecipe,
    required this.onUpdate,
    required this.onLoadList,
    required this.onExportMapping,
    required this.onRemove,
    required this.onReorder,
  });

  final List<RenameRule> rules;
  final int presetCount;
  final List<String> currentNames;
  final bool enabled;
  final bool canExportMapping;
  final ValueChanged<RenameRuleType> onAdd;
  final VoidCallback onManagePresets;
  final VoidCallback onLoadRecipe;
  final VoidCallback onSaveRecipe;
  final void Function(int, RenameRule) onUpdate;
  final ValueChanged<int> onLoadList;
  final VoidCallback onExportMapping;
  final ValueChanged<int> onRemove;
  final void Function(int, int) onReorder;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: surface,
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 18, 14, 14),
            child: Row(
              children: [
                const Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '改名規則',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      SizedBox(height: 3),
                      Text(
                        '依序套用，預覽會即時更新',
                        style: TextStyle(color: subtle, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                Tooltip(
                  message: '管理規則預設',
                  child: TextButton.icon(
                    key: const ValueKey('rule-presets-button'),
                    onPressed: enabled ? onManagePresets : null,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 40),
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                    ),
                    icon: const Icon(Icons.bookmarks_outlined, size: 18),
                    label: const Text('預設'),
                  ),
                ),
                const SizedBox(width: 5),
                PopupMenuButton<_RuleRecipeFileAction>(
                  key: const ValueKey('rule-recipe-menu'),
                  enabled: enabled,
                  tooltip: '規則配方檔',
                  onSelected: (action) {
                    switch (action) {
                      case _RuleRecipeFileAction.load:
                        onLoadRecipe();
                        return;
                      case _RuleRecipeFileAction.save:
                        onSaveRecipe();
                        return;
                    }
                  },
                  itemBuilder: (context) => [
                    const PopupMenuItem(
                      key: ValueKey('load-rule-recipe'),
                      value: _RuleRecipeFileAction.load,
                      child: Text('載入規則配方…'),
                    ),
                    PopupMenuItem(
                      key: const ValueKey('save-rule-recipe'),
                      value: _RuleRecipeFileAction.save,
                      enabled: rules.isNotEmpty,
                      child: const Text('匯出目前配方…'),
                    ),
                  ],
                  child: Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: surfaceRaised,
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: border),
                    ),
                    child: const Icon(
                      Icons.description_outlined,
                      color: subtle,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 5),
                PopupMenuButton<RenameRuleType>(
                  enabled: enabled,
                  tooltip: '新增規則',
                  onSelected: onAdd,
                  itemBuilder: (context) => RenameRuleType.values
                      .map(
                        (type) =>
                            PopupMenuItem(value: type, child: Text(type.label)),
                      )
                      .toList(),
                  child: Container(
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(
                        color: primary.withValues(alpha: 0.35),
                      ),
                    ),
                    child: const Icon(
                      Icons.add_rounded,
                      color: primaryBright,
                      size: 20,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: rules.isEmpty
                ? _EmptyRules(onAdd: enabled ? onAdd : null)
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    padding: const EdgeInsets.all(12),
                    itemCount: rules.length,
                    onReorderItem: enabled ? onReorder : (_, _) {},
                    proxyDecorator: (child, index, animation) => Material(
                      color: Colors.transparent,
                      elevation: 8,
                      child: child,
                    ),
                    itemBuilder: (context, index) {
                      final rule = rules[index];
                      return Padding(
                        key: ValueKey(rule.id),
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _RuleCard(
                          index: index,
                          rule: rule,
                          currentNames: currentNames,
                          enabled: enabled,
                          canExportMapping: canExportMapping,
                          onChanged: (value) => onUpdate(index, value),
                          onLoadList: () => onLoadList(index),
                          onExportMapping: onExportMapping,
                          onRemove: () => onRemove(index),
                        ),
                      );
                    },
                  ),
          ),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: border)),
            ),
            child: Text(
              rules.isEmpty
                  ? '尚未設定規則 · $presetCount 個預設'
                  : '已自動儲存 ${rules.length} 個規則 · $presetCount 個預設',
              style: const TextStyle(color: subtle, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyRules extends StatelessWidget {
  const _EmptyRules({required this.onAdd});

  final ValueChanged<RenameRuleType>? onAdd;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.layers_outlined, size: 40, color: subtle),
            const SizedBox(height: 14),
            const Text(
              '加入第一個改名規則',
              style: TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              '你可以依序組合取代、前後綴、大小寫與流水號',
              textAlign: TextAlign.center,
              style: TextStyle(color: subtle, fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onAdd == null
                  ? null
                  : () => onAdd!(RenameRuleType.newName),
              child: const Text('新增檔名規則'),
            ),
          ],
        ),
      ),
    );
  }
}

class _RuleCard extends StatelessWidget {
  const _RuleCard({
    required this.index,
    required this.rule,
    required this.currentNames,
    required this.enabled,
    required this.canExportMapping,
    required this.onChanged,
    required this.onLoadList,
    required this.onExportMapping,
    required this.onRemove,
  });

  final int index;
  final RenameRule rule;
  final List<String> currentNames;
  final bool enabled;
  final bool canExportMapping;
  final ValueChanged<RenameRule> onChanged;
  final VoidCallback onLoadList;
  final VoidCallback onExportMapping;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: surfaceRaised,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: rule.enabled ? primary.withValues(alpha: 0.32) : border,
        ),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 6),
            child: Row(
              children: [
                ReorderableDragStartListener(
                  index: index,
                  enabled: enabled,
                  child: const Padding(
                    padding: EdgeInsets.all(5),
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      color: subtle,
                      size: 19,
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${index + 1}. ${rule.type.label}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Switch.adaptive(
                  value: rule.enabled,
                  onChanged: enabled
                      ? (value) => onChanged(rule.copyWith(enabled: value))
                      : null,
                ),
                IconButton(
                  onPressed: enabled ? onRemove : null,
                  icon: const Icon(Icons.close_rounded, size: 18),
                  tooltip: '移除規則',
                  color: subtle,
                ),
              ],
            ),
          ),
          if (rule.enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: _RuleFields(
                rule: rule,
                currentNames: currentNames,
                enabled: enabled,
                canExportMapping: canExportMapping,
                onChanged: onChanged,
                onLoadList: onLoadList,
                onExportMapping: onExportMapping,
              ),
            ),
        ],
      ),
    );
  }
}

class _RuleFields extends StatelessWidget {
  const _RuleFields({
    required this.rule,
    required this.currentNames,
    required this.enabled,
    required this.canExportMapping,
    required this.onChanged,
    required this.onLoadList,
    required this.onExportMapping,
  });

  final RenameRule rule;
  final List<String> currentNames;
  final bool enabled;
  final bool canExportMapping;
  final ValueChanged<RenameRule> onChanged;
  final VoidCallback onLoadList;
  final VoidCallback onExportMapping;

  @override
  Widget build(BuildContext context) {
    final fields = switch (rule.type) {
      RenameRuleType.newName => TextFormField(
        key: ValueKey('${rule.id}-value'),
        initialValue: rule.value,
        enabled: enabled,
        decoration: const InputDecoration(
          labelText: '新檔名',
          hintText: '例如 假期-{n}',
          helperText: '可使用 {name} 與 {n}；預設不變更副檔名',
        ),
        onChanged: (value) => onChanged(rule.copyWith(value: value)),
      ),
      RenameRuleType.list => _ListRuleFields(
        rule: rule,
        currentNames: currentNames,
        enabled: enabled,
        canExportMapping: canExportMapping,
        onChanged: onChanged,
        onLoadList: onLoadList,
        onExportMapping: onExportMapping,
      ),
      RenameRuleType.replace => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextFormField(
            key: ValueKey('${rule.id}-find'),
            initialValue: rule.value,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: '尋找',
              hintText: '例如 IMG_',
            ),
            onChanged: (value) => onChanged(rule.copyWith(value: value)),
          ),
          const SizedBox(height: 9),
          TextFormField(
            key: ValueKey('${rule.id}-replace'),
            initialValue: rule.replacement,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: '取代為',
              hintText: '留白表示刪除',
            ),
            onChanged: (value) => onChanged(rule.copyWith(replacement: value)),
          ),
          const SizedBox(height: 7),
          _RuleOption(
            label: '區分大小寫',
            value: rule.caseSensitive,
            enabled: enabled,
            onChanged: (value) =>
                onChanged(rule.copyWith(caseSensitive: value)),
          ),
          _RuleOption(
            label: '使用正規表示式',
            value: rule.useRegex,
            enabled: enabled,
            onChanged: (value) => onChanged(rule.copyWith(useRegex: value)),
          ),
          if (rule.useRegex)
            const Padding(
              padding: EdgeInsets.only(left: 4, top: 2),
              child: Text(
                r'使用 RE2 語法；群組取代可輸入 \1、\2',
                style: TextStyle(color: subtle, fontSize: 11),
              ),
            ),
        ],
      ),
      RenameRuleType.prefix || RenameRuleType.suffix => TextFormField(
        key: ValueKey('${rule.id}-value'),
        initialValue: rule.value,
        enabled: enabled,
        decoration: InputDecoration(
          labelText: rule.type == RenameRuleType.prefix ? '前綴' : '後綴',
          hintText: rule.type == RenameRuleType.prefix
              ? '例如 Project-'
              : '例如 -final',
        ),
        onChanged: (value) => onChanged(rule.copyWith(value: value)),
      ),
      RenameRuleType.letterCase => DropdownButtonFormField<String>(
        key: ValueKey('${rule.id}-mode'),
        initialValue: rule.mode,
        decoration: const InputDecoration(labelText: '格式'),
        items: const [
          DropdownMenuItem(value: 'lower', child: Text('全部小寫')),
          DropdownMenuItem(value: 'upper', child: Text('全部大寫')),
          DropdownMenuItem(value: 'title', child: Text('每個單字首字大寫')),
        ],
        onChanged: enabled
            ? (mode) {
                if (mode != null) onChanged(rule.copyWith(mode: mode));
              }
            : null,
      ),
      RenameRuleType.sequence => Row(
        children: [
          Expanded(
            child: TextFormField(
              key: ValueKey('${rule.id}-start'),
              initialValue: rule.start.toString(),
              enabled: enabled,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '起始數字'),
              onChanged: (value) => onChanged(
                rule.copyWith(start: int.tryParse(value) ?? rule.start),
              ),
            ),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: DropdownButtonFormField<int>(
              key: ValueKey('${rule.id}-padding'),
              initialValue: rule.padding,
              decoration: const InputDecoration(labelText: '位數'),
              items: const [
                DropdownMenuItem(value: 1, child: Text('1')),
                DropdownMenuItem(value: 2, child: Text('2')),
                DropdownMenuItem(value: 3, child: Text('3')),
                DropdownMenuItem(value: 4, child: Text('4')),
                DropdownMenuItem(value: 5, child: Text('5')),
                DropdownMenuItem(value: 6, child: Text('6')),
              ],
              onChanged: enabled
                  ? (padding) {
                      if (padding != null) {
                        onChanged(rule.copyWith(padding: padding));
                      }
                    }
                  : null,
            ),
          ),
        ],
      ),
      RenameRuleType.trim => const Text(
        '將移除所選範圍頭尾的半形與全形空白',
        style: TextStyle(color: muted, fontSize: 12),
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        fields,
        const SizedBox(height: 10),
        DropdownButtonFormField<RenameRuleTarget>(
          key: ValueKey('${rule.id}-target'),
          initialValue: rule.target,
          decoration: const InputDecoration(labelText: '套用到'),
          items: RenameRuleTarget.values
              .map(
                (target) =>
                    DropdownMenuItem(value: target, child: Text(target.label)),
              )
              .toList(growable: false),
          onChanged: enabled
              ? (target) {
                  if (target != null) onChanged(rule.copyWith(target: target));
                }
              : null,
        ),
        if (rule.target == RenameRuleTarget.extension)
          const Padding(
            padding: EdgeInsets.only(left: 4, top: 5),
            child: Text(
              '副檔名不包含句點，例如 jpg',
              style: TextStyle(color: subtle, fontSize: 11),
            ),
          ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: background.withValues(alpha: 0.42),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(color: border),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: _RuleOption(
                  label: '只在符合條件時套用',
                  value: rule.condition.enabled,
                  enabled: enabled,
                  onChanged: (value) => onChanged(
                    rule.copyWith(
                      condition: rule.condition.copyWith(enabled: value),
                    ),
                  ),
                ),
              ),
              if (rule.condition.enabled)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 2, 10, 10),
                  child: _RuleConditionFields(
                    rule: rule,
                    enabled: enabled,
                    onChanged: onChanged,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ListRuleFields extends StatefulWidget {
  const _ListRuleFields({
    required this.rule,
    required this.currentNames,
    required this.enabled,
    required this.canExportMapping,
    required this.onChanged,
    required this.onLoadList,
    required this.onExportMapping,
  });

  final RenameRule rule;
  final List<String> currentNames;
  final bool enabled;
  final bool canExportMapping;
  final ValueChanged<RenameRule> onChanged;
  final VoidCallback onLoadList;
  final VoidCallback onExportMapping;

  @override
  State<_ListRuleFields> createState() => _ListRuleFieldsState();
}

class _ListRuleFieldsState extends State<_ListRuleFields> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.rule.values.join('\n'),
  );

  @override
  void didUpdateWidget(covariant _ListRuleFields oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!listEquals(oldWidget.rule.values, widget.rule.values)) {
      final text = widget.rule.values.join('\n');
      if (_controller.text != text) {
        _controller.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final itemCount = widget.currentNames.length;
    final nameCount = widget.rule.values.length;
    final hasMismatch =
        nameCount > 0 && itemCount > 0 && nameCount != itemCount;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: ValueKey('${widget.rule.id}-values'),
          controller: _controller,
          enabled: widget.enabled,
          minLines: 5,
          maxLines: 9,
          decoration: const InputDecoration(
            labelText: '名稱清單',
            hintText: '第一行對應第一個檔案\n第二行對應第二個檔案',
            alignLabelWithHint: true,
          ),
          onChanged: (text) => widget.onChanged(
            widget.rule.copyWith(values: parseRenameListText(text)),
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 7,
          runSpacing: 7,
          children: [
            OutlinedButton.icon(
              onPressed: widget.enabled && widget.currentNames.isNotEmpty
                  ? _populate
                  : null,
              icon: const Icon(Icons.playlist_add_rounded, size: 17),
              label: const Text('填入目前名稱'),
            ),
            OutlinedButton.icon(
              onPressed: widget.enabled ? widget.onLoadList : null,
              icon: const Icon(Icons.file_open_outlined, size: 17),
              label: const Text('載入 TXT/CSV'),
            ),
            OutlinedButton.icon(
              onPressed: widget.enabled && widget.canExportMapping
                  ? widget.onExportMapping
                  : null,
              icon: const Icon(Icons.download_outlined, size: 17),
              label: const Text('匯出對照表'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: Text(
            itemCount == 0 ? '$nameCount 個名稱' : '$nameCount / $itemCount 個名稱',
            style: TextStyle(
              color: hasMismatch ? danger : subtle,
              fontSize: 11,
              fontWeight: hasMismatch ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
        if (hasMismatch)
          const Padding(
            padding: EdgeInsets.only(top: 5, left: 4),
            child: Text(
              '名稱數量必須與檔案數量完全一致',
              style: TextStyle(color: danger, fontSize: 11),
            ),
          ),
      ],
    );
  }

  void _populate() {
    final values = widget.currentNames
        .map((name) => _listValueForTarget(name, widget.rule.target))
        .toList(growable: false);
    widget.onChanged(widget.rule.copyWith(values: values));
  }
}

String _fileNameFromPath(String path) {
  final slash = math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
  return slash < 0 ? path : path.substring(slash + 1);
}

String _listValueForTarget(String fileName, RenameRuleTarget target) {
  if (target == RenameRuleTarget.both) return fileName;
  final dot = fileName.lastIndexOf('.');
  final hasExtension = dot > 0 && dot < fileName.length - 1;
  if (target == RenameRuleTarget.extension) {
    return hasExtension ? fileName.substring(dot + 1) : '';
  }
  return hasExtension ? fileName.substring(0, dot) : fileName;
}

class _RuleConditionFields extends StatelessWidget {
  const _RuleConditionFields({
    required this.rule,
    required this.enabled,
    required this.onChanged,
  });

  final RenameRule rule;
  final bool enabled;
  final ValueChanged<RenameRule> onChanged;

  @override
  Widget build(BuildContext context) {
    final condition = rule.condition;
    void update(RenameRuleCondition value) {
      onChanged(rule.copyWith(condition: value));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<RenameConditionField>(
          key: ValueKey('${rule.id}-condition-field'),
          initialValue: condition.field,
          decoration: const InputDecoration(labelText: '判斷欄位'),
          items: RenameConditionField.values
              .map(
                (field) =>
                    DropdownMenuItem(value: field, child: Text(field.label)),
              )
              .toList(growable: false),
          onChanged: enabled
              ? (field) {
                  if (field != null) update(condition.copyWith(field: field));
                }
              : null,
        ),
        const SizedBox(height: 8),
        DropdownButtonFormField<RenameConditionOperator>(
          key: ValueKey('${rule.id}-condition-operator'),
          initialValue: condition.operator,
          decoration: const InputDecoration(labelText: '比對方式'),
          items: RenameConditionOperator.values
              .map(
                (operator) => DropdownMenuItem(
                  value: operator,
                  child: Text(operator.label),
                ),
              )
              .toList(growable: false),
          onChanged: enabled
              ? (operator) {
                  if (operator != null) {
                    update(condition.copyWith(operator: operator));
                  }
                }
              : null,
        ),
        const SizedBox(height: 8),
        TextFormField(
          key: ValueKey('${rule.id}-condition-value'),
          initialValue: condition.value,
          enabled: enabled,
          decoration: InputDecoration(
            labelText: '條件內容',
            hintText: condition.operator == RenameConditionOperator.regex
                ? r'例如 ^IMG_\d+$'
                : '例如 -done',
          ),
          onChanged: (value) => update(condition.copyWith(value: value)),
        ),
        const SizedBox(height: 3),
        _RuleOption(
          label: '反向條件（排除符合項目）',
          value: condition.negate,
          enabled: enabled,
          onChanged: (value) => update(condition.copyWith(negate: value)),
        ),
        Padding(
          padding: const EdgeInsets.only(left: 4, top: 1),
          child: Text(
            condition.operator == RenameConditionOperator.regex
                ? '使用 RE2 語法；條件比對不區分大小寫'
                : '條件比對不區分大小寫；留白會符合全部項目',
            style: const TextStyle(color: subtle, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _RuleOption extends StatelessWidget {
  const _RuleOption({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: enabled ? () => onChanged(!value) : null,
      borderRadius: BorderRadius.circular(7),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Checkbox(
              value: value,
              onChanged: enabled
                  ? (checked) => onChanged(checked ?? false)
                  : null,
              visualDensity: VisualDensity.compact,
            ),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

class _DirectoryImportDialog extends StatefulWidget {
  const _DirectoryImportDialog({required this.directoryCount});

  final int directoryCount;

  @override
  State<_DirectoryImportDialog> createState() => _DirectoryImportDialogState();
}

class _DirectoryImportDialogState extends State<_DirectoryImportDialog> {
  final _patternsController = TextEditingController();
  var _recursive = false;
  var _includeHidden = false;

  @override
  void dispose() {
    _patternsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: surfaceRaised,
      title: const Text('匯入資料夾'),
      content: SizedBox(
        width: 430,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '將掃描 ${widget.directoryCount} 個資料夾，只加入普通檔案。掃描本身不會修改檔案。',
              style: const TextStyle(color: muted, fontSize: 13),
            ),
            const SizedBox(height: 18),
            TextFormField(
              controller: _patternsController,
              decoration: const InputDecoration(
                labelText: '檔案篩選',
                hintText: '*.jpg;*.png',
                helperText: '可用分號或逗號分隔；留白表示全部檔案',
              ),
            ),
            const SizedBox(height: 10),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _recursive,
              title: const Text('包含子資料夾'),
              subtitle: const Text('不會跟隨 symbolic link'),
              onChanged: (value) => setState(() => _recursive = value ?? false),
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: _includeHidden,
              title: const Text('包含隱藏檔'),
              subtitle: const Text('包含名稱以 . 開頭的檔案與資料夾'),
              onChanged: (value) =>
                  setState(() => _includeHidden = value ?? false),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: () => Navigator.pop(
            context,
            DirectoryImportOptions(
              recursive: _recursive,
              includeHidden: _includeHidden,
              patterns: parseDirectoryPatterns(_patternsController.text),
            ),
          ),
          icon: const Icon(Icons.folder_open_rounded, size: 18),
          label: const Text('開始掃描'),
        ),
      ],
    );
  }
}

enum _AddSource { files, directory }

enum _FileListAction { load, save }

enum _PreviewPathAction { reveal, copy }

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({
    required this.paths,
    required this.plan,
    required this.visibleIndices,
    required this.searchController,
    required this.searchQuery,
    required this.sortField,
    required this.sortAscending,
    required this.collisionStrategy,
    required this.excludedPaths,
    required this.overridePaths,
    required this.selectedPaths,
    required this.activePath,
    required this.connected,
    required this.previewing,
    required this.previewPending,
    required this.previewFailed,
    required this.applying,
    required this.scanning,
    required this.dragging,
    required this.onChooseFiles,
    required this.onChooseDirectory,
    required this.onSaveFileList,
    required this.onLoadFileList,
    required this.onRevealPath,
    required this.onCopyPath,
    required this.onRemovePath,
    required this.onSetPathIncluded,
    required this.onSetAllPathsIncluded,
    required this.onSetSelectedPathsIncluded,
    required this.onSelectPath,
    required this.onClearSelection,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onSortFieldChanged,
    required this.onToggleSortDirection,
    required this.onCollisionStrategyChanged,
    required this.processingOrderVisible,
    required this.enabledOrderMoves,
    required this.onShowProcessingOrder,
    required this.onMoveSelectedPaths,
    required this.onEditProposedName,
    required this.onClearPaths,
    required this.onApply,
    required this.focusNode,
    required this.scrollController,
    required this.onKeyEvent,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDrop,
  });

  final List<String> paths;
  final RenamePlan? plan;
  final List<int> visibleIndices;
  final TextEditingController searchController;
  final String searchQuery;
  final PreviewSortField sortField;
  final bool sortAscending;
  final CollisionStrategy collisionStrategy;
  final Set<String> excludedPaths;
  final Set<String> overridePaths;
  final Set<String> selectedPaths;
  final String? activePath;
  final bool connected;
  final bool previewing;
  final bool previewPending;
  final bool previewFailed;
  final bool applying;
  final bool scanning;
  final bool dragging;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;
  final VoidCallback onSaveFileList;
  final VoidCallback onLoadFileList;
  final ValueChanged<String> onRevealPath;
  final ValueChanged<String> onCopyPath;
  final ValueChanged<String> onRemovePath;
  final void Function(String path, bool included) onSetPathIncluded;
  final ValueChanged<bool> onSetAllPathsIncluded;
  final ValueChanged<bool> onSetSelectedPathsIncluded;
  final ValueChanged<String> onSelectPath;
  final VoidCallback onClearSelection;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<PreviewSortField> onSortFieldChanged;
  final VoidCallback onToggleSortDirection;
  final ValueChanged<CollisionStrategy> onCollisionStrategyChanged;
  final bool processingOrderVisible;
  final Set<PreviewOrderMove> enabledOrderMoves;
  final VoidCallback onShowProcessingOrder;
  final ValueChanged<PreviewOrderMove> onMoveSelectedPaths;
  final Future<void> Function(String path, String proposedName)
  onEditProposedName;
  final VoidCallback onClearPaths;
  final VoidCallback onApply;
  final FocusNode focusNode;
  final ScrollController scrollController;
  final FocusOnKeyEventCallback onKeyEvent;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final ValueChanged<List<XFile>> onDrop;

  @override
  Widget build(BuildContext context) {
    final currentPlan = plan;
    final rowCount = currentPlan == null
        ? paths.length
        : [
            paths.length,
            currentPlan.sourcePaths.length,
            currentPlan.originalNames.length,
            currentPlan.proposedNames.length,
            currentPlan.targetPaths.length,
            currentPlan.statuses.length,
            currentPlan.messages.length,
            currentPlan.included.length,
            currentPlan.overridden.length,
            currentPlan.collisionResolved.length,
          ].reduce(math.min);
    final canApply =
        connected &&
        currentPlan != null &&
        currentPlan.errorCount == 0 &&
        currentPlan.renameableCount > 0 &&
        !previewing &&
        !previewPending &&
        !scanning &&
        !applying;
    final displayedIndices = visibleIndices
        .where((index) => index >= 0 && index < rowCount)
        .toList(growable: false);
    final displayedPaths = displayedIndices
        .map((index) => paths[index])
        .toList(growable: false);
    final includedCount = displayedPaths
        .where((path) => !excludedPaths.contains(path))
        .length;
    final includeAllValue =
        displayedPaths.isNotEmpty && includedCount == displayedPaths.length
        ? true
        : includedCount == 0
        ? false
        : null;

    return Focus(
      focusNode: focusNode,
      onKeyEvent: onKeyEvent,
      child: DropTarget(
        onDragEntered: (_) => onDragEntered(),
        onDragExited: (_) => onDragExited(),
        onDragDone: (detail) => onDrop(detail.files),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          color: dragging ? primary.withValues(alpha: 0.07) : background,
          child: Column(
            children: [
              Container(
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
                            '檔名預覽',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            '勾選框控制納入改名；點選整列可批次操作',
                            style: TextStyle(color: subtle, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    if (paths.isNotEmpty)
                      TextButton(
                        onPressed: applying || scanning ? null : onClearPaths,
                        child: const Text('全部清除'),
                      ),
                    const SizedBox(width: 6),
                    _FileListMenu(
                      enabled: connected && !applying && !scanning,
                      canSave: paths.isNotEmpty,
                      onLoad: onLoadFileList,
                      onSave: onSaveFileList,
                    ),
                    const SizedBox(width: 6),
                    _AddItemsMenu(
                      enabled: connected && !applying && !scanning,
                      onChooseFiles: onChooseFiles,
                      onChooseDirectory: onChooseDirectory,
                    ),
                  ],
                ),
              ),
              SizedBox(
                key: const ValueKey('preview-progress-slot'),
                height: 2,
                child: previewing || previewPending || scanning
                    ? const LinearProgressIndicator(minHeight: 2)
                    : const ColoredBox(color: Colors.transparent),
              ),
              if (paths.isNotEmpty)
                _PreviewTools(
                  controller: searchController,
                  query: searchQuery,
                  sortField: sortField,
                  ascending: sortAscending,
                  collisionStrategy: collisionStrategy,
                  visibleCount: displayedIndices.length,
                  totalCount: rowCount,
                  enabled: !applying && !scanning,
                  onSearchChanged: onSearchChanged,
                  onClearSearch: onClearSearch,
                  onSortFieldChanged: onSortFieldChanged,
                  onToggleSortDirection: onToggleSortDirection,
                  onCollisionStrategyChanged: onCollisionStrategyChanged,
                ),
              Expanded(
                child: paths.isEmpty
                    ? _DropEmptyState(
                        connected: connected,
                        scanning: scanning,
                        dragging: dragging,
                        onChooseFiles: onChooseFiles,
                        onChooseDirectory: onChooseDirectory,
                      )
                    : Column(
                        children: [
                          _PreviewColumns(
                            includeAllValue: includeAllValue,
                            filtered: displayedIndices.length != rowCount,
                            enabled:
                                displayedIndices.isNotEmpty &&
                                !applying &&
                                !scanning,
                            onChanged: onSetAllPathsIncluded,
                          ),
                          Expanded(
                            child: displayedIndices.isEmpty
                                ? _EmptyPreviewFilter(
                                    query: searchQuery,
                                    onClear: onClearSearch,
                                  )
                                : ListView.builder(
                                    key: const ValueKey('preview-list'),
                                    controller: scrollController,
                                    itemExtent: _previewRowExtent,
                                    itemCount: displayedIndices.length,
                                    itemBuilder: (context, rowIndex) {
                                      final index = displayedIndices[rowIndex];
                                      final inputPath = paths[index];
                                      final sourcePath = currentPlan == null
                                          ? inputPath
                                          : currentPlan.sourcePaths[index];
                                      return Column(
                                        children: [
                                          Expanded(
                                            child: _PreviewRow(
                                              key: ValueKey(
                                                'preview-row-$inputPath',
                                              ),
                                              sourcePath: sourcePath,
                                              targetPath: currentPlan
                                                  ?.targetPaths[index],
                                              originalName: currentPlan
                                                  ?.originalNames[index],
                                              proposedName: currentPlan
                                                  ?.proposedNames[index],
                                              status:
                                                  currentPlan?.statuses[index],
                                              message:
                                                  currentPlan?.messages[index],
                                              included: !excludedPaths.contains(
                                                inputPath,
                                              ),
                                              overridden: overridePaths
                                                  .contains(inputPath),
                                              collisionResolved:
                                                  currentPlan
                                                      ?.collisionResolved[index] ??
                                                  false,
                                              selected: selectedPaths.contains(
                                                inputPath,
                                              ),
                                              active: activePath == inputPath,
                                              previewFailed: previewFailed,
                                              onSelect: () =>
                                                  onSelectPath(inputPath),
                                              onIncludedChanged:
                                                  applying || scanning
                                                  ? null
                                                  : (included) =>
                                                        onSetPathIncluded(
                                                          inputPath,
                                                          included,
                                                        ),
                                              onEditName:
                                                  applying ||
                                                      scanning ||
                                                      currentPlan == null
                                                  ? null
                                                  : () => onEditProposedName(
                                                      inputPath,
                                                      currentPlan
                                                          .proposedNames[index],
                                                    ),
                                              onReveal: () =>
                                                  onRevealPath(inputPath),
                                              onCopyPath: () =>
                                                  onCopyPath(inputPath),
                                              onRemove: applying || scanning
                                                  ? null
                                                  : () =>
                                                        onRemovePath(inputPath),
                                            ),
                                          ),
                                          if (rowIndex + 1 <
                                              displayedIndices.length)
                                            const Divider(height: 1),
                                        ],
                                      );
                                    },
                                  ),
                          ),
                        ],
                      ),
              ),
              _ActionBar(
                plan: currentPlan,
                applying: applying,
                scanning: scanning,
                canApply: canApply,
                selectedCount: selectedPaths.length,
                processingOrderVisible: processingOrderVisible,
                enabledOrderMoves: enabledOrderMoves,
                onIncludeSelected: () => onSetSelectedPathsIncluded(true),
                onExcludeSelected: () => onSetSelectedPathsIncluded(false),
                onShowProcessingOrder: onShowProcessingOrder,
                onMoveSelectedPaths: onMoveSelectedPaths,
                onClearSelection: onClearSelection,
                onApply: onApply,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewTools extends StatelessWidget {
  const _PreviewTools({
    required this.controller,
    required this.query,
    required this.sortField,
    required this.ascending,
    required this.collisionStrategy,
    required this.visibleCount,
    required this.totalCount,
    required this.enabled,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.onSortFieldChanged,
    required this.onToggleSortDirection,
    required this.onCollisionStrategyChanged,
  });

  final TextEditingController controller;
  final String query;
  final PreviewSortField sortField;
  final bool ascending;
  final CollisionStrategy collisionStrategy;
  final int visibleCount;
  final int totalCount;
  final bool enabled;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final ValueChanged<PreviewSortField> onSortFieldChanged;
  final VoidCallback onToggleSortDirection;
  final ValueChanged<CollisionStrategy> onCollisionStrategyChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 54),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final search = TextField(
            key: const ValueKey('preview-search'),
            controller: controller,
            enabled: enabled,
            onChanged: onSearchChanged,
            decoration: InputDecoration(
              hintText: '搜尋檔名或路徑',
              prefixIcon: const Icon(Icons.search_rounded, size: 18),
              suffixIcon: query.isEmpty
                  ? null
                  : IconButton(
                      onPressed: onClearSearch,
                      tooltip: '清除搜尋',
                      icon: const Icon(Icons.close_rounded, size: 17),
                    ),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 9),
            ),
          );
          final collision = _CollisionStrategyPicker(
            strategy: collisionStrategy,
            enabled: enabled,
            onChanged: onCollisionStrategyChanged,
          );
          final sort = _PreviewSortPicker(
            field: sortField,
            enabled: enabled,
            onChanged: onSortFieldChanged,
          );
          final direction = IconButton(
            onPressed: enabled ? onToggleSortDirection : null,
            tooltip: ascending ? '改為降冪排序' : '改為升冪排序',
            icon: Icon(
              ascending
                  ? Icons.arrow_upward_rounded
                  : Icons.arrow_downward_rounded,
              size: 18,
            ),
          );
          final count = SizedBox(
            width: 64,
            child: Text(
              '$visibleCount / $totalCount',
              textAlign: TextAlign.right,
              style: const TextStyle(color: subtle, fontSize: 11),
            ),
          );

          if (constraints.maxWidth < 700) {
            return Column(
              children: [
                search,
                const SizedBox(height: 7),
                Row(
                  children: [
                    Expanded(child: collision),
                    const SizedBox(width: 8),
                    Expanded(child: sort),
                    direction,
                    count,
                  ],
                ),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: search),
              const SizedBox(width: 9),
              SizedBox(width: 184, child: collision),
              const SizedBox(width: 9),
              SizedBox(width: 150, child: sort),
              direction,
              count,
            ],
          );
        },
      ),
    );
  }
}

class _CollisionStrategyPicker extends StatelessWidget {
  const _CollisionStrategyPicker({
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
        CollisionStrategy.fail => '安全預設：發現重複目標時阻止套用',
        CollisionStrategy.appendNumber => '在副檔名前附加 (2)、(3)…，絕不覆寫原檔',
      },
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1117),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<CollisionStrategy>(
            key: const ValueKey('collision-strategy'),
            value: strategy,
            isExpanded: true,
            icon: const Icon(Icons.expand_more_rounded, size: 18),
            items: CollisionStrategy.values
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(
                      value.label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
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

class _PreviewSortPicker extends StatelessWidget {
  const _PreviewSortPicker({
    required this.field,
    required this.enabled,
    required this.onChanged,
  });

  final PreviewSortField field;
  final bool enabled;
  final ValueChanged<PreviewSortField> onChanged;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '其他排序只改變顯示；處理順序會影響流水號與名稱清單對應',
      child: Container(
        height: 38,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF0E1117),
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<PreviewSortField>(
            key: const ValueKey('preview-sort-field'),
            value: field,
            isExpanded: true,
            icon: const Icon(Icons.expand_more_rounded, size: 18),
            items: PreviewSortField.values
                .map(
                  (value) => DropdownMenuItem(
                    value: value,
                    child: Text(
                      value.label,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12),
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

class _EmptyPreviewFilter extends StatelessWidget {
  const _EmptyPreviewFilter({required this.query, required this.onClear});

  final String query;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.search_off_rounded, color: subtle, size: 34),
          const SizedBox(height: 10),
          Text(
            '找不到符合「$query」的檔案',
            style: const TextStyle(color: muted, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          TextButton(onPressed: onClear, child: const Text('清除搜尋')),
        ],
      ),
    );
  }
}

class _FileListMenu extends StatelessWidget {
  const _FileListMenu({
    required this.enabled,
    required this.canSave,
    required this.onLoad,
    required this.onSave,
  });

  final bool enabled;
  final bool canSave;
  final VoidCallback onLoad;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFFD5D8E1) : muted;
    return PopupMenuButton<_FileListAction>(
      key: const ValueKey('file-list-menu'),
      enabled: enabled,
      tooltip: '儲存或載入檔案清單',
      onSelected: (action) {
        switch (action) {
          case _FileListAction.load:
            onLoad();
          case _FileListAction.save:
            onSave();
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          key: ValueKey('load-file-list'),
          value: _FileListAction.load,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.file_open_outlined),
            title: Text('載入檔案清單'),
          ),
        ),
        PopupMenuItem(
          key: const ValueKey('save-file-list'),
          value: _FileListAction.save,
          enabled: canSave,
          child: const ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.save_outlined),
            title: Text('儲存檔案清單'),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: enabled ? const Color(0xFF3A4050) : border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.list_alt_rounded, size: 18, color: color),
            const SizedBox(width: 7),
            Text(
              '清單',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 3),
            Icon(Icons.arrow_drop_down_rounded, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

class _AddItemsMenu extends StatelessWidget {
  const _AddItemsMenu({
    required this.enabled,
    required this.onChooseFiles,
    required this.onChooseDirectory,
  });

  final bool enabled;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;

  @override
  Widget build(BuildContext context) {
    final color = enabled ? const Color(0xFFD5D8E1) : muted;
    return PopupMenuButton<_AddSource>(
      enabled: enabled,
      tooltip: '加入檔案或資料夾',
      onSelected: (source) {
        switch (source) {
          case _AddSource.files:
            onChooseFiles();
          case _AddSource.directory:
            onChooseDirectory();
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(
          value: _AddSource.files,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.insert_drive_file_outlined),
            title: Text('加入檔案'),
          ),
        ),
        PopupMenuItem(
          value: _AddSource.directory,
          child: ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(Icons.folder_open_outlined),
            title: Text('加入資料夾'),
          ),
        ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: enabled ? const Color(0xFF3A4050) : border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.add_rounded, size: 18, color: color),
            const SizedBox(width: 7),
            Text(
              '加入',
              style: TextStyle(color: color, fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 3),
            Icon(Icons.arrow_drop_down_rounded, size: 18, color: color),
          ],
        ),
      ),
    );
  }
}

class _DropEmptyState extends StatelessWidget {
  const _DropEmptyState({
    required this.connected,
    required this.scanning,
    required this.dragging,
    required this.onChooseFiles,
    required this.onChooseDirectory,
  });

  final bool connected;
  final bool scanning;
  final bool dragging;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxHeight < 340;
          return Container(
            constraints: const BoxConstraints(maxWidth: 500),
            margin: EdgeInsets.all(compact ? 16 : 28),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 24 : 36,
              vertical: compact ? 20 : 42,
            ),
            decoration: BoxDecoration(
              color: dragging
                  ? primary.withValues(alpha: 0.12)
                  : surface.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: dragging ? primary : border,
                width: dragging ? 2 : 1,
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  dragging
                      ? Icons.file_download_done_rounded
                      : Icons.file_open_outlined,
                  size: compact ? 36 : 48,
                  color: dragging ? primaryBright : subtle,
                ),
                SizedBox(height: compact ? 10 : 18),
                Text(
                  dragging ? '放開即可加入' : '拖放檔案或資料夾到這裡',
                  style: compact
                      ? Theme.of(context).textTheme.titleMedium
                      : Theme.of(context).textTheme.titleLarge,
                ),
                SizedBox(height: compact ? 6 : 8),
                const Text(
                  'Flick 只會在你確認後才真正修改檔名',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: muted),
                ),
                SizedBox(height: compact ? 12 : 22),
                Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: connected && !scanning ? onChooseFiles : null,
                      icon: const Icon(Icons.add_rounded, size: 18),
                      label: const Text('選擇檔案'),
                    ),
                    OutlinedButton.icon(
                      onPressed: connected && !scanning
                          ? onChooseDirectory
                          : null,
                      icon: const Icon(Icons.folder_open_outlined, size: 18),
                      label: const Text('選擇資料夾'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _PreviewColumns extends StatelessWidget {
  const _PreviewColumns({
    required this.includeAllValue,
    required this.filtered,
    required this.enabled,
    required this.onChanged,
  });

  final bool? includeAllValue;
  final bool filtered;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      color: const Color(0xFF0F1218),
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Tooltip(
              message: includeAllValue == true
                  ? filtered
                        ? '排除顯示中的檔案'
                        : '排除全部檔案'
                  : filtered
                  ? '納入顯示中的檔案'
                  : '納入全部檔案',
              child: Checkbox(
                key: const ValueKey('preview-include-visible'),
                tristate: true,
                value: includeAllValue,
                onChanged: enabled
                    ? (_) => onChanged(includeAllValue != true)
                    : null,
              ),
            ),
          ),
          const Text('納入', style: TextStyle(color: subtle, fontSize: 11)),
          const SizedBox(width: 4),
          const Expanded(
            flex: 5,
            child: Text('原始檔名', style: TextStyle(color: subtle, fontSize: 11)),
          ),
          const SizedBox(width: 18),
          const Expanded(
            flex: 5,
            child: Text('新檔名', style: TextStyle(color: subtle, fontSize: 11)),
          ),
          const SizedBox(width: 100),
          const SizedBox(width: 80),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    super.key,
    required this.sourcePath,
    required this.targetPath,
    required this.originalName,
    required this.proposedName,
    required this.status,
    required this.message,
    required this.included,
    required this.overridden,
    required this.collisionResolved,
    required this.selected,
    required this.active,
    required this.previewFailed,
    required this.onSelect,
    required this.onIncludedChanged,
    required this.onEditName,
    required this.onReveal,
    required this.onCopyPath,
    required this.onRemove,
  });

  final String sourcePath;
  final String? targetPath;
  final String? originalName;
  final String? proposedName;
  final String? status;
  final String? message;
  final bool included;
  final bool overridden;
  final bool collisionResolved;
  final bool selected;
  final bool active;
  final bool previewFailed;
  final VoidCallback onSelect;
  final ValueChanged<bool>? onIncludedChanged;
  final VoidCallback? onEditName;
  final VoidCallback onReveal;
  final VoidCallback onCopyPath;
  final VoidCallback? onRemove;

  void _handlePathAction(_PreviewPathAction action) {
    switch (action) {
      case _PreviewPathAction.reveal:
        onReveal();
      case _PreviewPathAction.copy:
        onCopyPath();
    }
  }

  Future<void> _showPathActions(
    BuildContext context,
    TapDownDetails details,
  ) async {
    final overlay = Overlay.of(context).context.findRenderObject();
    if (overlay is! RenderBox) return;
    final action = await showMenu<_PreviewPathAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(
          details.globalPosition.dx,
          details.globalPosition.dy,
          0,
          0,
        ),
        Offset.zero & overlay.size,
      ),
      items: _previewPathActionItems(),
    );
    if (action != null) _handlePathAction(action);
  }

  @override
  Widget build(BuildContext context) {
    final state = status ?? (previewFailed ? 'error' : 'loading');
    final color = !included
        ? subtle
        : switch (state) {
            'ready' => mint,
            'error' => danger,
            'unchanged' => subtle,
            _ => warning,
          };
    final icon = !included
        ? Icons.remove_circle_outline_rounded
        : switch (state) {
            'ready' => Icons.check_circle_rounded,
            'error' => Icons.error_rounded,
            'unchanged' => Icons.remove_circle_outline_rounded,
            _ => Icons.schedule_rounded,
          };
    final pathSegments = sourcePath
        .split(RegExp(r'[/\\]'))
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    final fallbackName = pathSegments.isEmpty ? null : pathSegments.last;
    return Semantics(
      selected: selected,
      button: true,
      label: originalName ?? fallbackName ?? sourcePath,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onSelect,
          onSecondaryTapDown: (details) =>
              unawaited(_showPathActions(context, details)),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOut,
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
            decoration: BoxDecoration(
              color: selected
                  ? primary.withValues(alpha: active ? 0.14 : 0.08)
                  : Colors.transparent,
              border: Border(
                left: BorderSide(
                  color: active ? primaryBright : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 40,
                  child: Tooltip(
                    message: included ? '取消納入（這次不改名）' : '納入這次改名',
                    child: Checkbox(
                      value: included,
                      onChanged: onIncludedChanged == null
                          ? null
                          : (value) => onIncludedChanged!(value ?? false),
                    ),
                  ),
                ),
                SizedBox(width: 28, child: Icon(icon, color: color, size: 18)),
                Expanded(
                  flex: 5,
                  child: Tooltip(
                    message:
                        '${originalName ?? fallbackName ?? sourcePath}\n$sourcePath',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Opacity(
                          opacity: included ? 1 : 0.45,
                          child: Text(
                            originalName ?? fallbackName ?? sourcePath,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Color(0xFFD5D8E1),
                              fontSize: 13,
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          sourcePath,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(color: subtle, fontSize: 10),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 18),
                Expanded(
                  flex: 5,
                  child: Tooltip(
                    message: [
                      proposedName ?? (previewFailed ? '預覽失敗' : '正在計算預覽…'),
                      ?targetPath,
                    ].join('\n'),
                    child: InkWell(
                      onTap: onEditName,
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            Expanded(
                              child: Opacity(
                                opacity: included ? 1 : 0.45,
                                child: Text(
                                  proposedName ??
                                      (previewFailed
                                          ? '預覽失敗，請檢查左側規則'
                                          : '正在計算預覽…'),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: state == 'error'
                                        ? danger
                                        : Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ),
                            if (overridden) ...[
                              const SizedBox(width: 6),
                              const Text(
                                '手動',
                                style: TextStyle(
                                  color: primaryBright,
                                  fontSize: 9,
                                ),
                              ),
                            ],
                            if (collisionResolved) ...[
                              const SizedBox(width: 6),
                              Text(
                                '流水號',
                                key: ValueKey('collision-resolved-$sourcePath'),
                                style: const TextStyle(
                                  color: warning,
                                  fontSize: 9,
                                ),
                              ),
                            ],
                            if (onEditName != null) ...[
                              const SizedBox(width: 5),
                              const Tooltip(
                                message: '點一下直接修改這個檔名',
                                child: Icon(
                                  Icons.edit_outlined,
                                  color: subtle,
                                  size: 14,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 100,
                  child: Text(
                    !included
                        ? '已排除'
                        : message?.isNotEmpty == true
                        ? message!
                        : collisionResolved
                        ? '已避開衝突'
                        : switch (state) {
                            'ready' => '可套用',
                            'unchanged' => '無變更',
                            'error' => '預覽失敗',
                            _ => '',
                          },
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: color, fontSize: 10),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: PopupMenuButton<_PreviewPathAction>(
                    key: ValueKey('preview-path-menu-$sourcePath'),
                    tooltip: '檔案動作',
                    onSelected: _handlePathAction,
                    itemBuilder: (context) => _previewPathActionItems(),
                    icon: const Icon(
                      Icons.more_horiz_rounded,
                      color: subtle,
                      size: 18,
                    ),
                  ),
                ),
                SizedBox(
                  width: 40,
                  child: IconButton(
                    onPressed: onRemove,
                    icon: const Icon(Icons.close_rounded, size: 17),
                    color: subtle,
                    tooltip: '移除檔案',
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

List<PopupMenuEntry<_PreviewPathAction>> _previewPathActionItems() {
  return const [
    PopupMenuItem(
      value: _PreviewPathAction.reveal,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.folder_open_outlined),
        title: Text('在檔案管理器中顯示'),
      ),
    ),
    PopupMenuItem(
      value: _PreviewPathAction.copy,
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.copy_rounded),
        title: Text('複製完整路徑'),
      ),
    ),
  ];
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.plan,
    required this.applying,
    required this.scanning,
    required this.canApply,
    required this.selectedCount,
    required this.processingOrderVisible,
    required this.enabledOrderMoves,
    required this.onIncludeSelected,
    required this.onExcludeSelected,
    required this.onShowProcessingOrder,
    required this.onMoveSelectedPaths,
    required this.onClearSelection,
    required this.onApply,
  });

  final RenamePlan? plan;
  final bool applying;
  final bool scanning;
  final bool canApply;
  final int selectedCount;
  final bool processingOrderVisible;
  final Set<PreviewOrderMove> enabledOrderMoves;
  final VoidCallback onIncludeSelected;
  final VoidCallback onExcludeSelected;
  final VoidCallback onShowProcessingOrder;
  final ValueChanged<PreviewOrderMove> onMoveSelectedPaths;
  final VoidCallback onClearSelection;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final current = plan;
    return Container(
      constraints: const BoxConstraints(minHeight: 70),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(top: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: selectedCount > 0
                ? Wrap(
                    spacing: 6,
                    runSpacing: 5,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        '$selectedCount 個已選',
                        style: const TextStyle(
                          color: primaryBright,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: applying || scanning
                            ? null
                            : onIncludeSelected,
                        icon: const Icon(Icons.check_rounded, size: 15),
                        label: const Text('納入'),
                      ),
                      TextButton.icon(
                        onPressed: applying || scanning
                            ? null
                            : onExcludeSelected,
                        icon: const Icon(Icons.block_rounded, size: 15),
                        label: const Text('排除'),
                      ),
                      if (!processingOrderVisible)
                        Tooltip(
                          message: '清除搜尋並切換至會影響流水號與名稱清單的處理順序',
                          child: TextButton.icon(
                            onPressed: applying || scanning
                                ? null
                                : onShowProcessingOrder,
                            icon: const Icon(Icons.swap_vert_rounded, size: 16),
                            label: const Text('顯示處理順序'),
                          ),
                        )
                      else ...[
                        _OrderMoveButton(
                          key: const ValueKey('move-selected-to-start'),
                          icon: Icons.vertical_align_top_rounded,
                          tooltip: '移到最前',
                          enabled:
                              !applying &&
                              !scanning &&
                              enabledOrderMoves.contains(
                                PreviewOrderMove.toStart,
                              ),
                          onPressed: () =>
                              onMoveSelectedPaths(PreviewOrderMove.toStart),
                        ),
                        _OrderMoveButton(
                          key: const ValueKey('move-selected-earlier'),
                          icon: Icons.keyboard_arrow_up_rounded,
                          tooltip: '向前移一格',
                          enabled:
                              !applying &&
                              !scanning &&
                              enabledOrderMoves.contains(
                                PreviewOrderMove.earlier,
                              ),
                          onPressed: () =>
                              onMoveSelectedPaths(PreviewOrderMove.earlier),
                        ),
                        _OrderMoveButton(
                          key: const ValueKey('move-selected-later'),
                          icon: Icons.keyboard_arrow_down_rounded,
                          tooltip: '向後移一格',
                          enabled:
                              !applying &&
                              !scanning &&
                              enabledOrderMoves.contains(
                                PreviewOrderMove.later,
                              ),
                          onPressed: () =>
                              onMoveSelectedPaths(PreviewOrderMove.later),
                        ),
                        _OrderMoveButton(
                          key: const ValueKey('move-selected-to-end'),
                          icon: Icons.vertical_align_bottom_rounded,
                          tooltip: '移到最後',
                          enabled:
                              !applying &&
                              !scanning &&
                              enabledOrderMoves.contains(
                                PreviewOrderMove.toEnd,
                              ),
                          onPressed: () =>
                              onMoveSelectedPaths(PreviewOrderMove.toEnd),
                        ),
                      ],
                      TextButton(
                        onPressed: onClearSelection,
                        child: const Text('取消選取'),
                      ),
                    ],
                  )
                : Wrap(
                    spacing: 9,
                    runSpacing: 7,
                    children: [
                      _CountBadge(
                        color: mint,
                        value: current?.renameableCount ?? 0,
                        label: '可改名',
                      ),
                      _CountBadge(
                        color: subtle,
                        value: current?.unchangedCount ?? 0,
                        label: '無變更',
                      ),
                      _CountBadge(
                        color: danger,
                        value: current?.errorCount ?? 0,
                        label: '錯誤',
                      ),
                      _CountBadge(
                        color: warning,
                        value: current?.excludedCount ?? 0,
                        label: '已排除',
                      ),
                    ],
                  ),
          ),
          const Spacer(),
          FilledButton.icon(
            onPressed: canApply ? onApply : null,
            icon: applying || scanning
                ? const SizedBox.square(
                    dimension: 17,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 19),
            label: Text(scanning ? '正在掃描…' : (applying ? '正在套用…' : '開始批次改名')),
          ),
        ],
      ),
    );
  }
}

class _OrderMoveButton extends StatelessWidget {
  const _OrderMoveButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      constraints: const BoxConstraints.tightFor(width: 36, height: 36),
      padding: const EdgeInsets.all(7),
      onPressed: enabled ? onPressed : null,
      tooltip: tooltip,
      icon: Icon(icon, size: 18),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({
    required this.color,
    required this.value,
    required this.label,
  });

  final Color color;
  final int value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$value $label',
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

String _friendlyError(Object error) {
  if (error is RpcException) {
    return switch (error.code) {
      'invalid_pattern' => '檔案篩選格式不正確，請使用例如 *.jpg;*.png',
      'too_many_items' => '檔案超過 $_maxRenameItems 個，請縮小資料夾範圍或使用檔案篩選',
      'empty_directories' => '請先選擇要掃描的資料夾',
      'invalid_directory' ||
      'directory_unavailable' ||
      'directory_required' => '無法讀取選取的資料夾',
      'invalid_rule' => '規則設定不完整，請檢查左側欄位',
      'list_count_mismatch' => '名稱清單的行數必須與檔案數量完全一致',
      'invalid_regex' => '正規表示式格式不正確，請檢查「尋找」欄位',
      'invalid_condition' => '條件設定不正確，請檢查規則中的條件欄位',
      'invalid_condition_regex' => '條件的正規表示式格式不正確',
      _ => error.message,
    };
  }
  if (error case FormatException(:final message)) return message.toString();
  if (error case FileSystemException(:final message)) return message;
  final text = error.toString();
  const prefix = 'BackendProtocolException: ';
  if (text.startsWith(prefix)) return text.substring(prefix.length);
  return text;
}
