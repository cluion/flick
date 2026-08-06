import 'dart:convert';
import 'dart:io';

import 'package:bridra_flutter/bridra_flutter.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:file_selector/file_selector.dart';
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    show FileSelectorPlatform;
import 'package:flick/api/backend_gateway.dart';
import 'package:flick/app/flick_app.dart';
import 'package:flick/domain/file_list_io.dart';
import 'package:flick/domain/rename_rule.dart';
import 'package:flick/domain/rule_configuration_history.dart';
import 'package:flick/domain/rule_preset.dart';
import 'package:flutter/gestures.dart'
    show PointerDeviceKind, kSecondaryMouseButton;
import 'package:flutter/material.dart'
    show
        EditableText,
        FilledButton,
        Icons,
        Offset,
        OutlinedButton,
        Size,
        SizedBox,
        Text,
        TextButton,
        TextFormField,
        ValueKey;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

class FakeBackend implements BackendGateway {
  final List<PreviewRenameRequest> previewRequests = [];

  PreviewRenameRequest? get lastPreviewRequest =>
      previewRequests.isEmpty ? null : previewRequests.last;

  @override
  Future<void> close() async {}

  @override
  Future<HealthInfo> health({RpcCancellationToken? cancellationToken}) async {
    return const HealthInfo(
      status: 'ok',
      frameworkVersion: '0.11.0',
      protocolVersion: 3,
      runtime: 'Go sidecar',
      architecture: 'Middleware -> Controller -> Service',
    );
  }

  @override
  Future<DirectoryScanResult> scanDirectories(
    ScanDirectoriesRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    return const DirectoryScanResult(paths: [], skippedCount: 0);
  }

  @override
  Future<RenameHistory> renameHistory({
    RpcCancellationToken? cancellationToken,
  }) async {
    return const RenameHistory(
      batchIds: [],
      timestamps: [],
      changedCounts: [],
      undoable: [],
    );
  }

  @override
  Future<RenamePlan> previewRename(
    PreviewRenameRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    previewRequests.add(request);
    final overrides = <String, String>{
      for (var index = 0; index < request.overridePaths.length; index++)
        request.overridePaths[index]: request.overrideNames[index],
    };
    final included = request.paths
        .map((path) => !request.excludedPaths.contains(path))
        .toList(growable: false);
    final proposedNames = request.paths
        .map((path) => overrides[path] ?? 'final.txt')
        .toList(growable: false);
    return RenamePlan(
      planId: 'plan-1',
      sourcePaths: request.paths,
      originalNames: request.paths.map(_fileName).toList(growable: false),
      proposedNames: proposedNames,
      targetPaths: proposedNames
          .map((name) => '/tmp/$name')
          .toList(growable: false),
      statuses: request.paths.map((_) => 'ready').toList(growable: false),
      messages: request.paths.map((_) => '').toList(growable: false),
      included: included,
      overridden: request.paths
          .map(overrides.containsKey)
          .toList(growable: false),
      sizes: List.generate(
        request.paths.length,
        (index) => (request.paths.length - index) * 10,
        growable: false,
      ),
      modifiedAt: List.generate(
        request.paths.length,
        (index) => (index + 1) * 100,
        growable: false,
      ),
      renameableCount: included.where((value) => value).length,
      unchangedCount: 0,
      errorCount: 0,
      excludedCount: included.where((value) => !value).length,
    );
  }

  static String _fileName(String path) {
    return path.split(RegExp(r'[/\\]')).last;
  }

  @override
  Future<ApplyRenameResult> applyRename(
    ApplyRenameRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    return const ApplyRenameResult(
      batchId: 'batch-1',
      changedCount: 1,
      message: 'Renamed 1 files.',
    );
  }

  @override
  Future<UndoRenameResult> undoRename(
    UndoRenameRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    return const UndoRenameResult(
      batchId: 'batch-1',
      changedCount: 1,
      message: 'Restored 1 files.',
    );
  }

  @override
  Stream<List<int>> download(
    RpcFileReference file, {
    Duration timeout = const Duration(minutes: 15),
    RpcCancellationToken? cancellationToken,
    int maxAttempts = 3,
  }) {
    return const Stream.empty();
  }

  @override
  Future<RpcFileReference> upload(
    RpcFileUpload file, {
    Duration timeout = const Duration(minutes: 15),
    RpcCancellationToken? cancellationToken,
    int maxAttempts = 3,
  }) async {
    throw UnsupportedError('FakeBackend.upload');
  }
}

class FakeFileSelector extends FileSelectorPlatform {
  XFile? openFileResult;
  FileSaveLocation? saveLocationResult;
  var openFileCalls = 0;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    openFileCalls++;
    return openFileResult;
  }

  @override
  Future<String?> getSavePath({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? suggestedName,
    String? confirmButtonText,
  }) async => saveLocationResult?.path;
}

void main() {
  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  tearDown(() {
    SharedPreferencesAsyncPlatform.instance = null;
  });

  testWidgets('renders the Flick rename workspace', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      FlickApp(
        connector: () async => FakeBackend(),
        versionLoader: () async => 'v0.2.1 (3)',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Flick'), findsOneWidget);
    expect(find.text('v0.2.1 (3)'), findsOneWidget);
    expect(find.text('本機引擎就緒'), findsOneWidget);
    expect(
      find.byTooltip('Go sidecar · Bridra 0.11.0 · Protocol 3'),
      findsOneWidget,
    );
    expect(find.text('改名規則'), findsOneWidget);
    expect(find.text('1. 設定新檔名'), findsOneWidget);
    expect(find.byIcon(Icons.drag_indicator_rounded), findsOneWidget);
    expect(find.byIcon(Icons.drag_handle), findsNothing);
    expect(find.text('拖放檔案或資料夾到這裡'), findsOneWidget);
    expect(find.text('選擇資料夾'), findsOneWidget);
    expect(find.text('開始批次改名'), findsOneWidget);

    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();
    expect(find.text('加入檔案'), findsOneWidget);
    expect(find.text('加入資料夾'), findsOneWidget);
    expect(find.byKey(const ValueKey('file-list-menu')), findsOneWidget);
  });

  testWidgets('creates, manages, applies, and restores rule presets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField).first, 'holiday-{n}');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('rule-presets-button')));
    await tester.pumpAndSettle();
    expect(find.text('尚未建立規則預設'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('save-current-rule-preset')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rule-preset-name-field')),
      '旅遊照片',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-rule-preset-name')));
    await tester.pumpAndSettle();
    expect(find.text('旅遊照片'), findsOneWidget);
    expect(find.text('1 個規則'), findsOneWidget);

    await tester.tap(find.byTooltip('預設選項'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新命名'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('rule-preset-name-field')),
      '旅行整理',
    );
    await tester.tap(find.byKey(const ValueKey('confirm-rule-preset-name')));
    await tester.pumpAndSettle();
    expect(find.text('旅行整理'), findsOneWidget);
    expect(find.text('旅遊照片'), findsNothing);

    await tester.tap(find.byTooltip('預設選項'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('複製預設'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-rule-preset-name')));
    await tester.pumpAndSettle();
    expect(find.text('旅行整理 複本'), findsOneWidget);

    await tester.tap(find.byTooltip('預設選項').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('刪除預設'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-delete-rule-preset')));
    await tester.pumpAndSettle();
    expect(find.text('旅行整理 複本'), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, '套用'));
    await tester.pumpAndSettle();
    expect(find.text('已套用規則預設「旅行整理」'), findsOneWidget);
    final ruleField = find.byType(TextFormField).first;
    final editor = tester.widget<EditableText>(
      find.descendant(of: ruleField, matching: find.byType(EditableText)),
    );
    expect(editor.controller.text, 'holiday-{n}');

    final stored = await SharedPreferencesAsync().getString(
      'flick.rule-presets.v1',
    );
    expect(stored, isNotNull);
    final presets = decodeRulePresets(stored!);
    expect(presets.map((preset) => preset.name), ['旅行整理']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();
    final restoredRuleField = find.byType(TextFormField).first;
    final restoredEditor = tester.widget<EditableText>(
      find.descendant(
        of: restoredRuleField,
        matching: find.byType(EditableText),
      ),
    );
    expect(restoredEditor.controller.text, 'holiday-{n}');
    await tester.tap(find.byKey(const ValueKey('rule-presets-button')));
    await tester.pumpAndSettle();
    expect(find.text('旅行整理'), findsOneWidget);
  });

  testWidgets('exports and safely imports versioned rule preset files', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final initialPreset = RulePreset(
      id: 'photos',
      name: '照片整理',
      rules: const [
        RenameRule(id: 'prefix', type: RenameRuleType.prefix, value: 'Trip-'),
      ],
    );
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({
          'flick.rule-presets.v1': encodeRulePresets([initialPreset]),
        });
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalSelector = FileSelectorPlatform.instance;
    final selector = FakeFileSelector();
    FileSelectorPlatform.instance = selector;
    addTearDown(() => FileSelectorPlatform.instance = originalSelector);
    final directory = Directory.systemTemp.createTempSync('flick-presets-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final allPresetsFile = File('${directory.path}/all.flickpreset');
    selector.saveLocationResult = FileSaveLocation(allPresetsFile.path);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule-presets-button')));
    await tester.pumpAndSettle();
    final exportAllButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('export-all-rule-presets')),
    );
    await tester.runAsync(() async {
      exportAllButton.onPressed!();
      for (
        var index = 0;
        index < 50 &&
            (!allPresetsFile.existsSync() || allPresetsFile.lengthSync() == 0);
        index++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();

    expect(allPresetsFile.existsSync(), isTrue);
    expect(
      decodeRulePresets(allPresetsFile.readAsStringSync()).single.name,
      '照片整理',
    );
    final exportedDialogText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .join(' | ');
    expect(
      find.textContaining('已將 1 個預設匯出到'),
      findsOneWidget,
      reason: exportedDialogText,
    );

    selector.openFileResult = XFile(allPresetsFile.path);
    final importButton = tester.widget<OutlinedButton>(
      find.byKey(const ValueKey('import-rule-presets')),
    );
    await tester.runAsync(() async {
      importButton.onPressed!();
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pumpAndSettle();
    expect(find.text('照片整理'), findsOneWidget);
    expect(find.text('照片整理（匯入）'), findsOneWidget);
    expect(find.textContaining('已從 all.flickpreset 匯入 1 個預設'), findsOneWidget);

    await tester.tap(find.byTooltip('預設選項').last);
    await tester.pumpAndSettle();
    expect(find.text('匯出預設'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('adds a safe built-in template to personal presets', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('rule-presets-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('starter-rule-presets')));
    await tester.pumpAndSettle();

    expect(find.text('內建安全範本'), findsOneWidget);
    expect(find.text('加上兩位流水號'), findsOneWidget);
    expect(find.text('清理空白並轉小寫'), findsOneWidget);
    expect(find.text('移除常見相機前綴'), findsOneWidget);
    expect(find.text('副檔名轉小寫'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey('add-starter-rule-preset-numbered')),
    );
    await tester.pumpAndSettle();

    expect(find.text('加上兩位流水號'), findsOneWidget);
    expect(find.text('2 個規則'), findsOneWidget);
    expect(find.text('已將內建範本「加上兩位流水號」加入我的預設'), findsOneWidget);
    final stored = await SharedPreferencesAsync().getString(
      'flick.rule-presets.v1',
    );
    final preset = decodeRulePresets(stored!).single;
    expect(preset.name, '加上兩位流水號');
    expect(preset.rules.map((rule) => rule.type), [
      RenameRuleType.suffix,
      RenameRuleType.sequence,
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('browses, applies, and clears recent rule configurations', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();
    final ruleField = find.byType(TextFormField).first;
    await tester.enterText(ruleField, 'holiday-{n}');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    await tester.enterText(ruleField, 'work-{n}');
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();

    final stored = await SharedPreferencesAsync().getString(
      'flick.rule-history.v1',
    );
    final history = decodeRuleConfigurationHistory(stored!);
    expect(history, hasLength(2));
    expect(history.first.rules.single.value, 'work-{n}');
    final holiday = history.last;

    await tester.tap(find.byKey(const ValueKey('rule-presets-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recent-rule-configurations')));
    await tester.pumpAndSettle();
    expect(find.text('最近使用的規則'), findsOneWidget);
    expect(find.text('設定新檔名：work-{n}'), findsOneWidget);
    expect(find.text('設定新檔名：holiday-{n}'), findsOneWidget);
    await tester.tap(
      find.byKey(ValueKey('apply-recent-rule-configuration-${holiday.id}')),
    );
    await tester.pumpAndSettle();

    final restoredField = find.byType(TextFormField).first;
    final restoredEditor = tester.widget<EditableText>(
      find.descendant(of: restoredField, matching: find.byType(EditableText)),
    );
    expect(restoredEditor.controller.text, 'holiday-{n}');
    expect(find.text('已套用最近的規則設定'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('rule-presets-button')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('recent-rule-configurations')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('clear-rule-history')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-clear-rule-history')));
    await tester.pumpAndSettle();
    expect(find.text('尚無最近規則設定'), findsOneWidget);
    final cleared = await SharedPreferencesAsync().getString(
      'flick.rule-history.v1',
    );
    expect(decodeRuleConfigurationHistory(cleared!), isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saves and restores file list workspace state', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalSelector = FileSelectorPlatform.instance;
    final selector = FakeFileSelector();
    FileSelectorPlatform.instance = selector;
    addTearDown(() => FileSelectorPlatform.instance = originalSelector);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = ['one.txt', 'two.txt']
        .map((name) => File('${directory.path}/$name')..writeAsStringSync(name))
        .toList(growable: false);
    final listFile = File('${directory.path}/saved.flicklist');
    selector.saveLocationResult = FileSaveLocation(listFile.path);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    await tester.tap(find.byTooltip('取消納入（這次不改名）').last);
    await _pumpAsyncWork(tester);
    await tester.tap(find.byTooltip('點一下直接修改這個檔名').first);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('manual-name-field')),
      'chosen.txt',
    );
    await tester.tap(find.text('套用到預覽'));
    await _pumpAsyncWork(tester);

    await tester.tap(find.byKey(const ValueKey('file-list-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-file-list')));
    await tester.runAsync(() async {
      for (
        var index = 0;
        index < 50 && (!listFile.existsSync() || listFile.lengthSync() == 0);
        index++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    await tester.pumpAndSettle();

    final saved = decodeFlickFileList(listFile.readAsStringSync());
    expect(
      saved.items.map((item) => item.path),
      files.map((file) => file.path),
    );
    expect(saved.items.map((item) => item.included), [true, false]);
    expect(saved.items.map((item) => item.overrideName), ['chosen.txt', null]);

    await tester.tap(find.text('全部清除'));
    await tester.pump();
    backend.previewRequests.clear();
    selector.openFileResult = XFile.fromData(
      utf8.encode(listFile.readAsStringSync()),
      name: 'saved.flicklist',
    );
    await tester.tap(find.byKey(const ValueKey('file-list-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('載入檔案清單').last);
    await tester.pump();
    for (
      var index = 0;
      index < 100 && backend.previewRequests.isEmpty;
      index++
    ) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(selector.openFileCalls, 1);
    final visibleText = tester
        .widgetList<Text>(find.byType(Text))
        .map((widget) => widget.data)
        .whereType<String>()
        .join(' | ');
    expect(
      backend.lastPreviewRequest,
      isNotNull,
      reason: 'Visible UI text after loading: $visibleText',
    );
    expect(
      backend.lastPreviewRequest?.paths,
      files.map((file) => file.path).toList(growable: false),
    );
    expect(backend.lastPreviewRequest?.excludedPaths, [files[1].path]);
    expect(backend.lastPreviewRequest?.overridePaths, [files[0].path]);
    expect(backend.lastPreviewRequest?.overrideNames, ['chosen.txt']);
    expect(find.text('chosen.txt'), findsOneWidget);
    expect(find.text('1 已排除'), findsOneWidget);
  });

  testWidgets('keeps the empty workspace inside a compact window', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1155, 517);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();

    expect(find.text('拖放檔案或資料夾到這裡'), findsOneWidget);
    expect(find.text('選擇檔案'), findsOneWidget);
    expect(find.text('選擇資料夾'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reveals and copies a file path from row actions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/a very long original name.txt')
      ..writeAsStringSync('fixture');
    final revealedPaths = <String>[];
    final copiedPaths = <String>[];
    final backend = FakeBackend();

    await tester.pumpWidget(
      FlickApp(
        connector: () async => backend,
        revealFile: (path) async => revealedPaths.add(path),
        copyPath: (path) async => copiedPaths.add(path),
      ),
    );
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);

    expect(
      find.byTooltip('a very long original name.txt\n${file.path}'),
      findsOneWidget,
    );
    expect(find.byTooltip('final.txt\n/tmp/final.txt'), findsOneWidget);

    await tester.tap(find.byKey(ValueKey('preview-path-menu-${file.path}')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('在檔案管理器中顯示').last);
    await tester.pumpAndSettle();
    expect(revealedPaths, [file.path]);

    final row = find.byKey(ValueKey('preview-row-${file.path}'));
    final gesture = await tester.startGesture(
      tester.getCenter(row),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.text('複製完整路徑'), findsOneWidget);
    await tester.tap(find.text('複製完整路徑'));
    await tester.pumpAndSettle();

    expect(copiedPaths, [file.path]);
    expect(find.text('已複製完整路徑：${file.path}'), findsOneWidget);
  });

  testWidgets('fits file list controls at the minimum desktop width', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/minimum-width.txt')
      ..writeAsStringSync('fixture');
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('檔案預覽'));
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);

    expect(find.byKey(const ValueKey('file-list-menu')), findsOneWidget);
    expect(
      find.byKey(ValueKey('preview-path-menu-${file.path}')),
      findsOneWidget,
    );
    expect(find.text('清單'), findsOneWidget);
    expect(find.text('加入'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows advanced replace controls', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('新增規則'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取代文字'));
    await tester.pumpAndSettle();

    expect(find.text('區分大小寫'), findsOneWidget);
    expect(find.text('使用正規表示式'), findsOneWidget);
    expect(find.text('套用到'), findsNWidgets(2));
  });

  testWidgets('populates and validates a list rename rule', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = ['one.txt', 'two.txt']
        .map((name) => File('${directory.path}/$name')..writeAsStringSync(name))
        .toList(growable: false);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    await tester.tap(find.byTooltip('新增規則'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('名稱清單'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('填入目前名稱'));
    expect(find.text('載入 TXT/CSV'), findsOneWidget);
    expect(find.text('匯出對照表'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '匯出對照表'))
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.text('填入目前名稱'));
    await _pumpAsyncWork(tester);

    expect(find.text('2 / 2 個名稱'), findsOneWidget);
    final recipe = jsonDecode(backend.lastPreviewRequest!.recipe) as Map;
    final listRule = (recipe['rules'] as List).last as Map;
    expect(listRule['type'], 'list');
    expect(listRule['values'], ['final', 'final']);

    final listField = find.byWidgetPredicate(
      (widget) =>
          widget is TextFormField && widget.controller?.text == 'final\nfinal',
    );
    expect(listField, findsOneWidget);
    await tester.enterText(listField, 'only-one');
    await tester.pump();
    expect(find.text('1 / 2 個名稱'), findsOneWidget);
    expect(find.text('名稱數量必須與檔案數量完全一致'), findsOneWidget);
  });

  testWidgets('filters and visually sorts the preview list', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = ['charlie.txt', 'alpha.jpg', 'bravo.png']
        .map((name) => File('${directory.path}/$name')..writeAsStringSync(name))
        .toList(growable: false);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    expect(find.text('3 / 3'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('preview-search')),
      'alpha',
    );
    await tester.pump();
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('alpha.jpg'), findsOneWidget);
    expect(find.text('charlie.txt'), findsNothing);
    expect(find.byTooltip('排除顯示中的檔案'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-include-visible')));
    await tester.pump();
    expect(find.byTooltip('納入顯示中的檔案'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 250));
    await _pumpAsyncWork(tester);
    expect(backend.lastPreviewRequest?.excludedPaths, [files[1].path]);

    await tester.tap(find.byTooltip('清除搜尋'));
    await tester.pump();
    final requestsBeforeSort = backend.previewRequests.length;
    await tester.tap(find.byKey(const ValueKey('preview-sort-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('檔案大小').last);
    await tester.pumpAndSettle();

    expect(
      tester.getTopLeft(find.text('bravo.png')).dy,
      lessThan(tester.getTopLeft(find.text('alpha.jpg')).dy),
    );
    expect(
      tester.getTopLeft(find.text('alpha.jpg')).dy,
      lessThan(tester.getTopLeft(find.text('charlie.txt')).dy),
    );
    expect(backend.previewRequests.length, requestsBeforeSort);

    await tester.tap(find.byTooltip('改為降冪排序'));
    await tester.pump();
    expect(
      tester.getTopLeft(find.text('charlie.txt')).dy,
      lessThan(tester.getTopLeft(find.text('bravo.png')).dy),
    );
  });

  testWidgets('expands per-rule condition controls', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();

    expect(find.text('只在符合條件時套用'), findsOneWidget);
    expect(find.text('判斷欄位'), findsNothing);

    await tester.tap(find.text('只在符合條件時套用'));
    await tester.pumpAndSettle();

    expect(find.text('判斷欄位'), findsOneWidget);
    expect(find.text('比對方式'), findsOneWidget);
    expect(find.text('條件內容'), findsOneWidget);
    expect(find.text('反向條件（排除符合項目）'), findsOneWidget);
  });

  testWidgets('excludes one file from the rename preview', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/draft.txt');
    file.writeAsStringSync('fixture');
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);

    expect(find.byTooltip('取消納入（這次不改名）'), findsOneWidget);
    await tester.tap(find.byTooltip('取消納入（這次不改名）'));
    await _pumpAsyncWork(tester);

    expect(backend.lastPreviewRequest?.excludedPaths, [file.path]);
    expect(find.text('1 已排除'), findsOneWidget);
    expect(find.text('0 可改名'), findsOneWidget);
  });

  testWidgets('keeps and clears a manual preview name', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/draft.txt');
    file.writeAsStringSync('fixture');
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);

    await tester.tap(find.byTooltip('點一下直接修改這個檔名'));
    await _pumpAsyncWork(tester);
    await tester.enterText(
      find.byKey(const ValueKey('manual-name-field')),
      'chosen.md',
    );
    await tester.tap(find.text('套用到預覽'));
    await _pumpAsyncWork(tester);

    expect(backend.lastPreviewRequest?.overridePaths, [file.path]);
    expect(backend.lastPreviewRequest?.overrideNames, ['chosen.md']);
    expect(find.text('chosen.md'), findsOneWidget);
    expect(find.text('手動'), findsOneWidget);

    await tester.tap(find.byTooltip('點一下直接修改這個檔名'));
    await _pumpAsyncWork(tester);
    await tester.tap(find.text('恢復規則結果'));
    await _pumpAsyncWork(tester);

    expect(backend.lastPreviewRequest?.overridePaths, isEmpty);
    expect(find.text('final.txt'), findsOneWidget);
    expect(find.text('手動'), findsNothing);
  });

  testWidgets('debounces rapid exclusions without shifting the list', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/draft.txt');
    file.writeAsStringSync('fixture');
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);

    final baselineRequests = backend.previewRequests.length;
    final columnsY = tester.getTopLeft(find.text('原始檔名')).dy;
    final progressSlot = find.byKey(const ValueKey('preview-progress-slot'));
    expect(tester.getSize(progressSlot).height, 2);

    await tester.tap(find.byTooltip('取消納入（這次不改名）'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(backend.previewRequests.length, baselineRequests);
    expect(tester.getTopLeft(find.text('原始檔名')).dy, columnsY);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '開始批次改名'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byTooltip('納入這次改名'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byTooltip('取消納入（這次不改名）'));
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.previewRequests.length, baselineRequests);
    expect(tester.getTopLeft(find.text('原始檔名')).dy, columnsY);

    await tester.pump(const Duration(milliseconds: 150));
    await _pumpAsyncWork(tester);
    expect(backend.previewRequests.length, baselineRequests + 1);
    expect(backend.lastPreviewRequest?.excludedPaths, [file.path]);
    expect(tester.getTopLeft(find.text('原始檔名')).dy, columnsY);
    expect(tester.getSize(progressSlot).height, 2);
  });

  testWidgets('selects a range and changes inclusion in bulk', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = ['one.txt', 'two.txt', 'three.txt']
        .map((name) => File('${directory.path}/$name')..writeAsStringSync(name))
        .toList(growable: false);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    await tester.tap(find.text('one.txt'));
    await tester.pump();
    expect(find.text('1 個已選'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('three.txt'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text('3 個已選'), findsOneWidget);

    await tester.tap(find.text('排除'));
    await _pumpAsyncWork(tester);
    expect(
      backend.lastPreviewRequest?.excludedPaths,
      files.map((file) => file.path).toList(growable: false),
    );
    expect(find.byTooltip('納入全部檔案'), findsOneWidget);

    await tester.tap(find.byTooltip('納入全部檔案'));
    await _pumpAsyncWork(tester);
    expect(backend.lastPreviewRequest?.excludedPaths, isEmpty);

    await tester.tap(find.text('取消選取'));
    await tester.pump();
    expect(find.text('3 個已選'), findsNothing);
  });

  testWidgets('reorders selected items in processing order', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1155, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = ['one.txt', 'two.txt', 'three.txt']
        .map((name) => File('${directory.path}/$name')..writeAsStringSync(name))
        .toList(growable: false);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    await tester.tap(find.text('two.txt'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('move-selected-earlier')));
    await _pumpAsyncWork(tester);

    expect(backend.lastPreviewRequest?.paths, [
      files[1].path,
      files[0].path,
      files[2].path,
    ]);
    expect(
      tester.getTopLeft(find.text('two.txt')).dy,
      lessThan(tester.getTopLeft(find.text('one.txt')).dy),
    );
    expect(find.text('1 個已選'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('preview-sort-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('原始檔名').last);
    await tester.pumpAndSettle();
    expect(find.text('顯示處理順序'), findsOneWidget);

    await tester.tap(find.text('顯示處理順序'));
    await tester.pump();
    expect(find.text('顯示處理順序'), findsNothing);
    expect(find.byKey(const ValueKey('move-selected-later')), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('two.txt')).dy,
      lessThan(tester.getTopLeft(find.text('one.txt')).dy),
    );

    await tester.tap(find.byKey(const ValueKey('move-selected-later')));
    await _pumpAsyncWork(tester);
    expect(
      backend.lastPreviewRequest?.paths,
      files.map((file) => file.path).toList(growable: false),
    );
  });

  testWidgets('supports preview keyboard navigation and editing', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-widget-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = ['one.txt', 'two.txt', 'three.txt']
        .map((name) => File('${directory.path}/$name')..writeAsStringSync(name))
        .toList(growable: false);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    await tester.tap(find.text('one.txt'));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _pumpAsyncWork(tester);
    expect(backend.lastPreviewRequest?.excludedPaths, [files[1].path]);

    await tester.sendKeyEvent(LogicalKeyboardKey.f2);
    await tester.pumpAndSettle();
    expect(find.text('修改這個檔名'), findsOneWidget);
    await tester.enterText(
      find.byKey(const ValueKey('manual-name-field')),
      'keyboard-name.txt',
    );
    await tester.tap(find.text('套用到預覽'));
    await _pumpAsyncWork(tester);
    expect(backend.lastPreviewRequest?.overridePaths, [files[1].path]);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.text('修改這個檔名'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('3 個已選'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('3 個已選'), findsNothing);
  });
}

Future<void> _pumpAsyncWork(WidgetTester tester) async {
  for (var index = 0; index < 6; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _dropFile(WidgetTester tester, String path, FakeBackend backend) {
  return _dropFiles(tester, [path], backend);
}

Future<void> _dropFiles(
  WidgetTester tester,
  List<String> paths,
  FakeBackend backend,
) async {
  final target = tester.widget<DropTarget>(find.byType(DropTarget));
  await tester.runAsync(() async {
    target.onDragDone!(
      DropDoneDetails(
        files: paths.map(DropItemFile.new).toList(growable: false),
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    for (var index = 0; index < 20; index++) {
      if (backend.lastPreviewRequest != null) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
}
