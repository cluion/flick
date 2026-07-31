import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:bridra_flutter/bridra_flutter.dart' show RpcException;
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../api/backend_gateway.dart';
import '../domain/directory_import_options.dart';
import '../domain/rename_rule.dart';
import 'flick_app.dart';

const _savedRulesKey = 'flick.rename-rules.v2';
const _maxRenameItems = 10000;

class RenameWorkspace extends StatefulWidget {
  const RenameWorkspace({super.key, required this.connector});

  final BackendConnector connector;

  @override
  State<RenameWorkspace> createState() => _RenameWorkspaceState();
}

class _RenameWorkspaceState extends State<RenameWorkspace> {
  BackendGateway? _backend;
  HealthInfo? _health;
  RenamePlan? _plan;
  RenameHistory? _history;
  List<String> _paths = const [];
  List<RenameRule> _rules = [RenameRule.create(RenameRuleType.newName)];
  Timer? _previewTimer;
  Object? _error;
  String? _notice;
  var _connecting = true;
  var _previewing = false;
  var _previewFailed = false;
  var _scanning = false;
  var _applying = false;
  var _dragging = false;
  var _previewGeneration = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    await _restoreRules();
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

  Future<void> _restoreRules() async {
    try {
      final preferences = SharedPreferencesAsync();
      final saved = await preferences.getString(_savedRulesKey);
      if (saved == null) return;
      final rules = decodeSavedRules(saved);
      if (rules.isNotEmpty && mounted) setState(() => _rules = rules);
    } on Object {
      // Presets are optional and must never block the workspace.
    }
  }

  Future<void> _saveRules() async {
    try {
      final preferences = SharedPreferencesAsync();
      await preferences.setString(_savedRulesKey, encodeSavedRules(_rules));
    } on Object {
      // Preview and rename remain available if preference storage is unavailable.
    }
  }

  Future<void> _chooseFiles() async {
    try {
      final files = await openFiles();
      _addPaths(files.map((file) => file.path));
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
      _notice = notice;
      _error = null;
    });
    _schedulePreview(immediate: true);
  }

  void _removePath(String path) {
    setState(() {
      _paths = _paths.where((candidate) => candidate != path).toList();
      _plan = null;
    });
    _schedulePreview(immediate: true);
  }

  void _clearPaths() {
    _previewGeneration++;
    _previewTimer?.cancel();
    setState(() {
      _paths = const [];
      _plan = null;
      _error = null;
      _previewFailed = false;
    });
  }

  void _updateRule(int index, RenameRule rule) {
    final rules = [..._rules]..[index] = rule;
    setState(() {
      _rules = List.unmodifiable(rules);
      _notice = null;
    });
    unawaited(_saveRules());
    _schedulePreview();
  }

  void _addRule(RenameRuleType type) {
    setState(() {
      _rules = [..._rules, RenameRule.create(type)];
    });
    unawaited(_saveRules());
    _schedulePreview();
  }

  void _removeRule(int index) {
    setState(() {
      _rules = [..._rules]..removeAt(index);
    });
    unawaited(_saveRules());
    _schedulePreview();
  }

  void _reorderRule(int oldIndex, int newIndex) {
    final rules = [..._rules];
    final rule = rules.removeAt(oldIndex);
    rules.insert(newIndex, rule);
    setState(() => _rules = List.unmodifiable(rules));
    unawaited(_saveRules());
    _schedulePreview();
  }

  void _schedulePreview({bool immediate = false}) {
    _previewTimer?.cancel();
    if (_paths.isEmpty || _backend == null) {
      if (mounted) setState(() => _plan = null);
      return;
    }
    if (immediate) {
      unawaited(_preview());
      return;
    }
    _previewTimer = Timer(const Duration(milliseconds: 220), () {
      unawaited(_preview());
    });
  }

  Future<void> _preview() async {
    final backend = _backend;
    if (backend == null || _paths.isEmpty) return;
    final generation = ++_previewGeneration;
    setState(() {
      _previewing = true;
      _previewFailed = false;
      _error = null;
    });
    try {
      final plan = await backend.previewRename(
        PreviewRenameRequest(paths: _paths, recipe: encodeRenameRecipe(_rules)),
      );
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _plan = plan;
        _previewFailed = false;
      });
    } on Object catch (error) {
      if (!mounted || generation != _previewGeneration) return;
      setState(() {
        _plan = null;
        _previewFailed = true;
        _error = error;
      });
    } finally {
      if (mounted && generation == _previewGeneration) {
        setState(() => _previewing = false);
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
        _plan = null;
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
        _plan = null;
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
                connected: connected,
                connecting: _connecting,
                canUndo: canUndo,
                busy: _applying || _scanning,
                onUndo: _undoLatest,
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
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final rules = _RulesPanel(
                      rules: _rules,
                      enabled: connected && !_applying && !_scanning,
                      onAdd: _addRule,
                      onUpdate: _updateRule,
                      onRemove: _removeRule,
                      onReorder: _reorderRule,
                    );
                    final preview = _PreviewPanel(
                      paths: _paths,
                      plan: _plan,
                      connected: connected,
                      previewing: _previewing,
                      previewFailed: _previewFailed,
                      applying: _applying,
                      scanning: _scanning,
                      dragging: _dragging,
                      onChooseFiles: _chooseFiles,
                      onChooseDirectory: _chooseDirectory,
                      onRemovePath: _removePath,
                      onClearPaths: _clearPaths,
                      onApply: _apply,
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
                        Expanded(child: TabBarView(children: [rules, preview])),
                      ],
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkspaceHeader extends StatelessWidget {
  const _WorkspaceHeader({
    required this.connected,
    required this.connecting,
    required this.canUndo,
    required this.busy,
    required this.onUndo,
  });

  final bool connected;
  final bool connecting;
  final bool canUndo;
  final bool busy;
  final VoidCallback onUndo;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 68,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: const BoxDecoration(
        color: surface,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: primary,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.drive_file_rename_outline_rounded,
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
          const SizedBox(width: 10),
          const Text('批次檔名整理', style: TextStyle(color: subtle, fontSize: 13)),
          const Spacer(),
          _ConnectionStatus(connected: connected, connecting: connecting),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: canUndo && !busy ? onUndo : null,
            icon: const Icon(Icons.undo_rounded, size: 18),
            label: const Text('復原上一批'),
          ),
        ],
      ),
    );
  }
}

class _ConnectionStatus extends StatelessWidget {
  const _ConnectionStatus({required this.connected, required this.connecting});

  final bool connected;
  final bool connecting;

  @override
  Widget build(BuildContext context) {
    final color = connected ? mint : (connecting ? warning : danger);
    final label = connected ? '本機引擎就緒' : (connecting ? '連線中' : '引擎離線');
    return Container(
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

class _RulesPanel extends StatelessWidget {
  const _RulesPanel({
    required this.rules,
    required this.enabled,
    required this.onAdd,
    required this.onUpdate,
    required this.onRemove,
    required this.onReorder,
  });

  final List<RenameRule> rules;
  final bool enabled;
  final ValueChanged<RenameRuleType> onAdd;
  final void Function(int, RenameRule) onUpdate;
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
                          enabled: enabled,
                          onChanged: (value) => onUpdate(index, value),
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
              rules.isEmpty ? '尚未設定規則' : '已自動儲存 ${rules.length} 個規則',
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
    required this.enabled,
    required this.onChanged,
    required this.onRemove,
  });

  final int index;
  final RenameRule rule;
  final bool enabled;
  final ValueChanged<RenameRule> onChanged;
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
                enabled: enabled,
                onChanged: onChanged,
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
    required this.enabled,
    required this.onChanged,
  });

  final RenameRule rule;
  final bool enabled;
  final ValueChanged<RenameRule> onChanged;

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

class _PreviewPanel extends StatelessWidget {
  const _PreviewPanel({
    required this.paths,
    required this.plan,
    required this.connected,
    required this.previewing,
    required this.previewFailed,
    required this.applying,
    required this.scanning,
    required this.dragging,
    required this.onChooseFiles,
    required this.onChooseDirectory,
    required this.onRemovePath,
    required this.onClearPaths,
    required this.onApply,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDrop,
  });

  final List<String> paths;
  final RenamePlan? plan;
  final bool connected;
  final bool previewing;
  final bool previewFailed;
  final bool applying;
  final bool scanning;
  final bool dragging;
  final VoidCallback onChooseFiles;
  final VoidCallback onChooseDirectory;
  final ValueChanged<String> onRemovePath;
  final VoidCallback onClearPaths;
  final VoidCallback onApply;
  final VoidCallback onDragEntered;
  final VoidCallback onDragExited;
  final ValueChanged<List<XFile>> onDrop;

  @override
  Widget build(BuildContext context) {
    final currentPlan = plan;
    final rowCount = currentPlan == null
        ? paths.length
        : [
            currentPlan.sourcePaths.length,
            currentPlan.originalNames.length,
            currentPlan.proposedNames.length,
            currentPlan.statuses.length,
            currentPlan.messages.length,
          ].reduce(math.min);
    final canApply =
        connected &&
        currentPlan != null &&
        currentPlan.errorCount == 0 &&
        currentPlan.renameableCount > 0 &&
        !previewing &&
        !scanning &&
        !applying;

    return DropTarget(
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
                          '綠色表示可套用，紅色表示需要處理',
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
                  _AddItemsMenu(
                    enabled: connected && !applying && !scanning,
                    onChooseFiles: onChooseFiles,
                    onChooseDirectory: onChooseDirectory,
                  ),
                ],
              ),
            ),
            if (previewing || scanning)
              const LinearProgressIndicator(minHeight: 2),
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
                        const _PreviewColumns(),
                        Expanded(
                          child: ListView.separated(
                            itemCount: rowCount,
                            separatorBuilder: (_, _) =>
                                const Divider(height: 1),
                            itemBuilder: (context, index) {
                              final sourcePath = currentPlan == null
                                  ? paths[index]
                                  : currentPlan.sourcePaths[index];
                              return _PreviewRow(
                                sourcePath: sourcePath,
                                originalName: currentPlan?.originalNames[index],
                                proposedName: currentPlan?.proposedNames[index],
                                status: currentPlan?.statuses[index],
                                message: currentPlan?.messages[index],
                                previewFailed: previewFailed,
                                onRemove: applying || scanning
                                    ? null
                                    : () => onRemovePath(sourcePath),
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
              onApply: onApply,
            ),
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
      child: Container(
        constraints: const BoxConstraints(maxWidth: 500),
        margin: const EdgeInsets.all(28),
        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 42),
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
              size: 48,
              color: dragging ? primaryBright : subtle,
            ),
            const SizedBox(height: 18),
            Text(
              dragging ? '放開即可加入' : '拖放檔案或資料夾到這裡',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Flick 只會在你確認後才真正修改檔名',
              textAlign: TextAlign.center,
              style: TextStyle(color: muted),
            ),
            const SizedBox(height: 22),
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
                  onPressed: connected && !scanning ? onChooseDirectory : null,
                  icon: const Icon(Icons.folder_open_outlined, size: 18),
                  label: const Text('選擇資料夾'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewColumns extends StatelessWidget {
  const _PreviewColumns();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 18),
      color: const Color(0xFF0F1218),
      child: const Row(
        children: [
          SizedBox(width: 34),
          Expanded(
            flex: 5,
            child: Text('原始檔名', style: TextStyle(color: subtle, fontSize: 11)),
          ),
          SizedBox(width: 18),
          Expanded(
            flex: 5,
            child: Text('新檔名', style: TextStyle(color: subtle, fontSize: 11)),
          ),
          SizedBox(width: 100),
          SizedBox(width: 40),
        ],
      ),
    );
  }
}

class _PreviewRow extends StatelessWidget {
  const _PreviewRow({
    required this.sourcePath,
    required this.originalName,
    required this.proposedName,
    required this.status,
    required this.message,
    required this.previewFailed,
    required this.onRemove,
  });

  final String sourcePath;
  final String? originalName;
  final String? proposedName;
  final String? status;
  final String? message;
  final bool previewFailed;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final state = status ?? (previewFailed ? 'error' : 'loading');
    final color = switch (state) {
      'ready' => mint,
      'error' => danger,
      'unchanged' => subtle,
      _ => warning,
    };
    final icon = switch (state) {
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
    return Container(
      constraints: const BoxConstraints(minHeight: 64),
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      child: Row(
        children: [
          SizedBox(width: 34, child: Icon(icon, color: color, size: 18)),
          Expanded(
            flex: 5,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  originalName ?? fallbackName ?? sourcePath,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFD5D8E1),
                    fontSize: 13,
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
          const SizedBox(width: 18),
          Expanded(
            flex: 5,
            child: Text(
              proposedName ?? (previewFailed ? '預覽失敗，請檢查左側規則' : '正在計算預覽…'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: state == 'error' ? danger : Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          SizedBox(
            width: 100,
            child: Text(
              message?.isNotEmpty == true
                  ? message!
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
            child: IconButton(
              onPressed: onRemove,
              icon: const Icon(Icons.close_rounded, size: 17),
              color: subtle,
              tooltip: '移除檔案',
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({
    required this.plan,
    required this.applying,
    required this.scanning,
    required this.canApply,
    required this.onApply,
  });

  final RenamePlan? plan;
  final bool applying;
  final bool scanning;
  final bool canApply;
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
          _CountBadge(
            color: mint,
            value: current?.renameableCount ?? 0,
            label: '可改名',
          ),
          const SizedBox(width: 9),
          _CountBadge(
            color: subtle,
            value: current?.unchangedCount ?? 0,
            label: '無變更',
          ),
          const SizedBox(width: 9),
          _CountBadge(
            color: danger,
            value: current?.errorCount ?? 0,
            label: '錯誤',
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
      'invalid_regex' => '正規表示式格式不正確，請檢查「尋找」欄位',
      _ => error.message,
    };
  }
  final text = error.toString();
  const prefix = 'BackendProtocolException: ';
  if (text.startsWith(prefix)) return text.substring(prefix.length);
  return text;
}
