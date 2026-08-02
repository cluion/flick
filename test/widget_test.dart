import 'dart:convert';
import 'dart:io';

import 'package:bridra_flutter/bridra_flutter.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flick/api/backend_gateway.dart';
import 'package:flick/app/flick_app.dart';
import 'package:flutter/material.dart'
    show FilledButton, Icons, Offset, Size, TextFormField, ValueKey;
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
      frameworkVersion: '0.9.0',
      protocolVersion: 2,
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

void main() {
  testWidgets('renders the Flick rename workspace', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      FlickApp(
        connector: () async => FakeBackend(),
        versionLoader: () async => 'v0.1.0 (1)',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Flick'), findsOneWidget);
    expect(find.text('v0.1.0 (1)'), findsOneWidget);
    expect(find.text('本機引擎就緒'), findsOneWidget);
    expect(
      find.byTooltip('Go sidecar · Bridra 0.9.0 · Protocol 2'),
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

    expect(find.byTooltip('排除這個檔案'), findsOneWidget);
    await tester.tap(find.byTooltip('排除這個檔案'));
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

    await tester.tap(find.byTooltip('排除這個檔案'));
    await tester.pump(const Duration(milliseconds: 40));
    expect(backend.previewRequests.length, baselineRequests);
    expect(tester.getTopLeft(find.text('原始檔名')).dy, columnsY);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '開始批次改名'))
          .onPressed,
      isNull,
    );

    await tester.tap(find.byTooltip('重新納入這個檔案'));
    await tester.pump(const Duration(milliseconds: 40));
    await tester.tap(find.byTooltip('排除這個檔案'));
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
