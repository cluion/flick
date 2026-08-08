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
import 'package:flick/domain/organization_workspace.dart';
import 'package:flick/domain/rename_rule.dart';
import 'package:flick/domain/rule_configuration_history.dart';
import 'package:flick/domain/rule_preset.dart';
import 'package:flick/domain/rule_recipe_file.dart';
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
  final List<ScanDirectoriesRequest> directoryScanRequests = [];
  final List<PreviewOrganizationRequest> organizationPreviewRequests = [];
  final List<ApplyOrganizationRequest> organizationApplyRequests = [];
  final List<UndoOrganizationRequest> organizationUndoRequests = [];
  OrganizationPlan? lastOrganizationPlan;
  String? organizationItemError;
  bool organizationCrossVolume = false;
  bool organizationDuplicateTargets = false;
  bool organizationBatchExists = false;
  bool organizationUndoable = false;

  PreviewRenameRequest? get lastPreviewRequest =>
      previewRequests.isEmpty ? null : previewRequests.last;

  @override
  Future<void> close() async {}

  @override
  Future<HealthInfo> health({RpcCancellationToken? cancellationToken}) async {
    return const HealthInfo(
      status: 'ok',
      frameworkVersion: '0.11.0',
      protocolVersion: 9,
      runtime: 'Go sidecar',
      architecture: 'Middleware -> Controller -> Service',
    );
  }

  @override
  Future<DirectoryScanResult> scanDirectories(
    ScanDirectoriesRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    directoryScanRequests.add(request);
    return const DirectoryScanResult(paths: [], skippedCount: 0);
  }

  @override
  Future<OrganizationPlan> previewOrganization(
    PreviewOrganizationRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    organizationPreviewRequests.add(request);
    final folderPaths = request.folderNames
        .map((name) => joinOrganizationPath(request.rootPath, name))
        .toList(growable: false);
    final folderCreated = folderPaths
        .map((path) => !Directory(path).existsSync())
        .toList(growable: false);
    final folderStatuses = List.generate(
      folderPaths.length,
      (index) => folderCreated[index] ? 'ready' : 'existing',
      growable: false,
    );
    final targetPaths = <String>[];
    final statuses = <String>[];
    final messages = <String>[];
    final operationKinds = <String>[];
    final collisionResolved = List.filled(request.itemIds.length, false);
    for (var index = 0; index < request.itemIds.length; index++) {
      final destinationId = request.destinationFolderIds[index];
      if (destinationId.isEmpty) {
        targetPaths.add(request.sourcePaths[index]);
        statuses.add('unchanged');
        messages.add('The file will remain in its original location.');
        operationKinds.add('unchanged');
        continue;
      }
      final folderIndex = request.folderIds.indexOf(destinationId);
      final targetPath = joinOrganizationPath(
        folderPaths[folderIndex],
        organizationDuplicateTargets
            ? 'same.txt'
            : organizationFileName(request.sourcePaths[index]),
      );
      targetPaths.add(targetPath);
      statuses.add(organizationItemError == null ? 'ready' : 'error');
      messages.add(organizationItemError ?? '');
      operationKinds.add('move');
    }
    if (request.collisionStrategy == 'appendNumber') {
      final assigned = <String>{};
      for (var index = 0; index < targetPaths.length; index++) {
        if (operationKinds[index] != 'move' || statuses[index] == 'error') {
          continue;
        }
        final original = targetPaths[index];
        var candidate = original;
        var sequence = 2;
        while (assigned.contains(candidate) ||
            FileSystemEntity.typeSync(candidate, followLinks: false) !=
                FileSystemEntityType.notFound) {
          candidate = joinOrganizationPath(
            File(original).parent.path,
            _numberedName(organizationFileName(original), sequence++),
          );
          collisionResolved[index] = true;
        }
        assigned.add(candidate);
        targetPaths[index] = candidate;
        if (collisionResolved[index]) {
          messages[index] = 'The collision was resolved by appending a number.';
        }
      }
    } else {
      final targetIndexes = <String, List<int>>{};
      for (var index = 0; index < targetPaths.length; index++) {
        targetIndexes.putIfAbsent(targetPaths[index], () => []).add(index);
      }
      for (final indexes in targetIndexes.values) {
        if (indexes.length < 2) continue;
        for (final index in indexes) {
          statuses[index] = 'error';
          messages[index] = 'Multiple files would occupy the same target path.';
        }
      }
    }
    final moveCount = List.generate(
      statuses.length,
      (index) => statuses[index] == 'ready' && operationKinds[index] == 'move',
    ).where((value) => value).length;
    final unchangedCount = statuses
        .where((status) => status == 'unchanged')
        .length;
    final errorCount = statuses.where((status) => status == 'error').length;
    final crossVolumeCount = List.generate(
      statuses.length,
      (index) =>
          statuses[index] == 'ready' &&
          operationKinds[index] == 'move' &&
          organizationCrossVolume,
    ).where((value) => value).length;
    final plan = OrganizationPlan(
      planId: 'organization-plan-1',
      rootPath: request.rootPath,
      folderIds: request.folderIds,
      folderNames: request.folderNames,
      folderPaths: folderPaths,
      folderStatuses: folderStatuses,
      folderMessages: List.generate(folderPaths.length, (_) => ''),
      folderCreated: folderCreated,
      itemIds: request.itemIds,
      sourcePaths: request.sourcePaths,
      targetPaths: targetPaths,
      itemStatuses: statuses,
      itemMessages: messages,
      itemOperationKinds: operationKinds,
      itemCrossVolume: List.generate(
        request.itemIds.length,
        (index) =>
            statuses[index] == 'ready' &&
            operationKinds[index] == 'move' &&
            organizationCrossVolume,
      ),
      itemCategories: request.sourcePaths
          .map(_fakeOrganizationCategory)
          .toList(growable: false),
      itemCategoryReasons: request.sourcePaths
          .map(
            (path) => _fakeOrganizationCategory(path) == 'other'
                ? 'unknown'
                : 'extension:${_fakeExtension(path)}',
          )
          .toList(growable: false),
      itemCollisionResolved: collisionResolved,
      sizes: List.generate(request.itemIds.length, (_) => 7),
      modifiedAt: List.generate(request.itemIds.length, (_) => 100),
      mkdirCount: folderCreated.where((value) => value).length,
      moveCount: moveCount,
      unchangedCount: unchangedCount,
      errorCount: errorCount,
      crossVolumeCount: crossVolumeCount,
    );
    lastOrganizationPlan = plan;
    return plan;
  }

  @override
  Future<ApplyOrganizationResult> applyOrganization(
    ApplyOrganizationRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    organizationApplyRequests.add(request);
    organizationBatchExists = true;
    organizationUndoable = true;
    return const ApplyOrganizationResult(
      batchId: 'organization-batch-1',
      movedCount: 1,
      createdFolderCount: 1,
      message: 'Created 1 folders and moved 1 files.',
    );
  }

  @override
  Future<UndoOrganizationResult> undoOrganization(
    UndoOrganizationRequest request, {
    RpcCancellationToken? cancellationToken,
  }) async {
    organizationUndoRequests.add(request);
    organizationUndoable = false;
    return const UndoOrganizationResult(
      batchId: 'organization-batch-1',
      restoredCount: 1,
      removedFolderCount: 1,
      retainedFolderCount: 0,
      message: 'Restored 1 files and removed 1 empty folder.',
    );
  }

  @override
  Future<OrganizationHistory> organizationHistory({
    RpcCancellationToken? cancellationToken,
  }) async {
    if (!organizationBatchExists) {
      return const OrganizationHistory(
        batchIds: [],
        timestamps: [],
        movedCounts: [],
        createdFolderCounts: [],
        undoable: [],
      );
    }
    return OrganizationHistory(
      batchIds: const ['organization-batch-1'],
      timestamps: [DateTime.utc(2026, 8, 8)],
      movedCounts: const [1],
      createdFolderCounts: const [1],
      undoable: [organizationUndoable],
    );
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
    final collisionResolved = List.filled(request.paths.length, false);
    if (request.collisionStrategy == 'appendNumber') {
      final assigned = <String>{};
      for (var index = 0; index < proposedNames.length; index++) {
        final original = proposedNames[index];
        var candidate = original;
        var sequence = 2;
        while (!assigned.add(candidate)) {
          candidate = _numberedName(original, sequence++);
          collisionResolved[index] = true;
        }
        proposedNames[index] = candidate;
      }
    }
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
      collisionResolved: collisionResolved,
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

  static String _numberedName(String name, int sequence) {
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return '$name ($sequence)';
    return '${name.substring(0, dot)} ($sequence)${name.substring(dot)}';
  }

  static String _fakeOrganizationCategory(String path) {
    return switch (_fakeExtension(path)) {
      '.jpg' || '.jpeg' || '.png' => 'image',
      '.mp4' || '.mov' || '.mkv' => 'video',
      '.mp3' || '.wav' || '.flac' => 'audio',
      '.txt' || '.md' || '.pdf' => 'document',
      '.zip' || '.7z' || '.rar' => 'archive',
      _ => 'other',
    };
  }

  static String _fakeExtension(String path) {
    final name = _fileName(path);
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? '' : name.substring(dot).toLowerCase();
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
        versionLoader: () async => 'v0.4.0 (5)',
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Flick'), findsOneWidget);
    expect(find.text('v0.4.0 (5)'), findsOneWidget);
    expect(find.text('本機引擎就緒'), findsOneWidget);
    expect(
      find.byTooltip('Go sidecar · Bridra 0.11.0 · Protocol 9'),
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

  testWidgets(
    'stages files across renamed virtual folders without disk writes',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      tester.view.physicalSize = const Size(800, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final directory = Directory.systemTemp.createTempSync('flick-organize-');
      addTearDown(() => directory.deleteSync(recursive: true));
      final file = File('${directory.path}/photo.jpg')
        ..writeAsStringSync('original');
      final backend = FakeBackend();

      await tester.pumpWidget(FlickApp(connector: () async => backend));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
      await tester.pumpAndSettle();

      expect(find.text('視覺整理工作區'), findsOneWidget);
      expect(find.text('加入檔案，開始規劃資料夾'), findsOneWidget);
      await _dropFile(tester, file.path, backend);
      await _pumpAsyncWork(tester);
      expect(find.text(directory.path), findsOneWidget);
      expect(
        find.byKey(const ValueKey('organization-backend-verified')),
        findsOneWidget,
      );
      expect(backend.organizationPreviewRequests.last.rootPath, directory.path);
      expect(backend.organizationPreviewRequests.last.sourcePaths, [file.path]);

      await tester.tap(find.byKey(const ValueKey('organization-new-folder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('virtual-folder-name-field')),
        '圖片',
      );
      await tester.tap(find.text('建立'));
      await tester.pumpAndSettle();

      final item = find.byKey(const ValueKey('organization-item-0'));
      final photos = find.byKey(const ValueKey('organization-folder-0'));
      await _dragTo(tester, item, photos);
      await tester.pumpAndSettle();
      await tester.tap(photos);
      await tester.pumpAndSettle();

      expect(backend.organizationPreviewRequests.last.destinationFolderIds, [
        'organization-folder-0',
      ]);

      expect(
        find.text(
          joinOrganizationPath(
            joinOrganizationPath(directory.path, '圖片'),
            'photo.jpg',
          ),
        ),
        findsOneWidget,
      );
      expect(find.text('規劃移動'), findsOneWidget);
      expect(find.text('1 規劃移動'), findsOneWidget);
      expect(file.existsSync(), isTrue);
      expect(file.readAsStringSync(), 'original');
      expect(
        Directory(joinOrganizationPath(directory.path, '圖片')).existsSync(),
        isFalse,
      );

      await tester.tap(
        find.byKey(const ValueKey('rename-organization-folder-圖片')),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('virtual-folder-name-field')),
        '相片',
      );
      await tester.tap(find.text('重新命名'));
      await tester.pumpAndSettle();
      expect(backend.organizationPreviewRequests.last.folderNames.first, '相片');
      expect(
        find.text(
          joinOrganizationPath(
            joinOrganizationPath(directory.path, '相片'),
            'photo.jpg',
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('organization-new-folder')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('virtual-folder-name-field')),
        '精選',
      );
      await tester.tap(find.text('建立'));
      await tester.pumpAndSettle();
      final featured = find.byKey(const ValueKey('organization-folder-1'));
      await _dragTo(tester, item, featured);
      await tester.pumpAndSettle();
      await tester.tap(featured);
      await tester.pumpAndSettle();
      expect(
        find.text(
          joinOrganizationPath(
            joinOrganizationPath(directory.path, '精選'),
            'photo.jpg',
          ),
        ),
        findsOneWidget,
      );

      final root = find.byKey(const ValueKey('organization-folder-root'));
      await _dragTo(tester, item, root);
      await tester.pumpAndSettle();
      await tester.tap(root);
      await tester.pumpAndSettle();
      expect(find.text(file.path), findsOneWidget);
      expect(find.text('保留原位'), findsOneWidget);
      expect(find.text('1 保留原位'), findsOneWidget);
      expect(file.existsSync(), isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows backend organization conflicts without enabling apply', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-conflict-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/photo.jpg')
      ..writeAsStringSync('original');
    final backend = FakeBackend()
      ..organizationItemError =
          'An unrelated item already occupies the target path.';

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);
    await tester.tap(find.byKey(const ValueKey('organization-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('virtual-folder-name-field')),
      '圖片',
    );
    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();
    final item = find.byKey(const ValueKey('organization-item-0'));
    final folder = find.byKey(const ValueKey('organization-folder-0'));
    await _dragTo(tester, item, folder);
    await tester.pumpAndSettle();
    await tester.tap(folder);
    await tester.pumpAndSettle();

    expect(find.text('最終路徑已被其他項目占用'), findsOneWidget);
    expect(find.text('待處理'), findsOneWidget);
    expect(find.text('1 待處理'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('organization-folder-errors')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('organization-folder-errors-圖片')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const ValueKey('organization-folder-root')));
    await tester.pumpAndSettle();
    expect(find.text('最終路徑已被其他項目占用'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('organization-error-count')));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(const ValueKey('organization-item-panel-title')),
          )
          .data,
      '全部待處理',
    );
    expect(find.text('最終路徑已被其他項目占用'), findsOneWidget);
    expect(find.text('開始整理'), findsOneWidget);
    expect(file.readAsStringSync(), 'original');
    expect(
      Directory(joinOrganizationPath(directory.path, '圖片')).existsSync(),
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('handles a directory drop with one confirmation dialog', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1280, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'flick-directory-drop-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    final targets = tester
        .widgetList<DropTarget>(find.byType(DropTarget, skipOffstage: false))
        .toList(growable: false);
    expect(targets, hasLength(2));
    expect(targets.where((target) => target.enable), hasLength(1));
    final details = DropDoneDetails(
      files: [DropItemFile(directory.path)],
      localPosition: Offset.zero,
      globalPosition: Offset.zero,
    );
    await tester.runAsync(() async {
      for (final target in targets) {
        target.onDragDone?.call(details);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    await tester.pumpAndSettle();

    expect(find.text('匯入資料夾'), findsOneWidget);
    expect(find.text('開始掃描'), findsOneWidget);
    await tester.tap(find.text('開始掃描'));
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();

    expect(find.text('匯入資料夾'), findsNothing);
    expect(backend.directoryScanRequests, hasLength(1));
    expect(backend.directoryScanRequests.single.directories, [directory.path]);
    await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
    await tester.pumpAndSettle();
    final organizeTargets = tester
        .widgetList<DropTarget>(find.byType(DropTarget, skipOffstage: false))
        .toList(growable: false);
    expect(organizeTargets, hasLength(2));
    expect(organizeTargets.where((target) => target.enable), hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('numbers organization collisions without overwriting', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'flick-organize-number-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final first = File('${directory.path}/one.txt')..writeAsStringSync('first');
    final second = File('${directory.path}/two.txt')
      ..writeAsStringSync('second');
    final backend = FakeBackend()..organizationDuplicateTargets = true;

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
    await tester.pumpAndSettle();
    await _dropFiles(tester, [first.path, second.path], backend);
    await _pumpAsyncWork(tester);
    await tester.tap(find.byKey(const ValueKey('organization-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('virtual-folder-name-field')),
      '文件',
    );
    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();
    final folder = find.byKey(const ValueKey('organization-folder-0'));
    await _dragTo(
      tester,
      find.byKey(const ValueKey('organization-item-0')),
      folder,
    );
    await _pumpAsyncWork(tester);
    await _dragTo(
      tester,
      find.byKey(const ValueKey('organization-item-1')),
      folder,
    );
    await _pumpAsyncWork(tester);

    expect(backend.organizationPreviewRequests.last.collisionStrategy, 'fail');
    expect(backend.lastOrganizationPlan?.errorCount, 2);
    await tester.tap(
      find.byKey(const ValueKey('organization-collision-strategy')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自動附加流水號').last);
    await _pumpAsyncWork(tester);

    expect(
      backend.organizationPreviewRequests.last.collisionStrategy,
      'appendNumber',
    );
    expect(backend.lastOrganizationPlan?.errorCount, 0);
    expect(backend.lastOrganizationPlan?.itemCollisionResolved, [false, true]);
    await tester.tap(folder);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<Text>(
            find.byKey(
              const ValueKey('organization-target-organization-item-1'),
            ),
          )
          .data,
      endsWith('same (2).txt'),
    );
    expect(find.text('已加編號'), findsOneWidget);
    final applyButton = find.byKey(const ValueKey('apply-organization'));
    expect(tester.widget<FilledButton>(applyButton).onPressed, isNotNull);
    expect(first.readAsStringSync(), 'first');
    expect(second.readAsStringSync(), 'second');
    expect(tester.takeException(), isNull);
  });

  testWidgets('classifies every unassigned file into quick folders', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-categories-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files =
        [
              'photo.jpg',
              'movie.mp4',
              'song.mp3',
              'report.pdf',
              'bundle.zip',
              'mystery.bin',
            ]
            .map(
              (name) =>
                  File('${directory.path}/$name')..writeAsStringSync(name),
            )
            .toList(growable: false);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    expect(backend.lastOrganizationPlan?.itemCategories, [
      'image',
      'video',
      'audio',
      'document',
      'archive',
      'other',
    ]);
    expect(
      backend.lastOrganizationPlan?.itemCategoryReasons,
      everyElement(isNotEmpty),
    );
    expect(
      find.byKey(const ValueKey('organization-category-organization-item-0')),
      findsOneWidget,
    );
    expect(find.text('圖片 1'), findsOneWidget);
    expect(find.text('影片 1'), findsOneWidget);
    expect(find.text('音訊 1'), findsOneWidget);
    expect(find.text('文件 1'), findsOneWidget);
    expect(find.text('壓縮檔 1'), findsOneWidget);
    expect(find.text('其他 1'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('organization-classify-all')));
    await _pumpAsyncWork(tester);

    expect(backend.organizationPreviewRequests.last.folderNames, [
      '圖片',
      '影片',
      '音訊',
      '文件',
      '壓縮檔',
      '其他',
    ]);
    expect(
      backend.organizationPreviewRequests.last.destinationFolderIds.toSet(),
      hasLength(6),
    );
    expect(
      backend.organizationPreviewRequests.last.destinationFolderIds,
      isNot(contains('')),
    );
    expect(find.textContaining('已依偵測結果規劃 6 個檔案'), findsOneWidget);
    for (final folder in const ['圖片', '影片', '音訊', '文件', '壓縮檔', '其他']) {
      expect(Directory('${directory.path}/$folder').existsSync(), isFalse);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('quick classification preserves manual folder placement', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync(
      'flick-category-manual-',
    );
    addTearDown(() => directory.deleteSync(recursive: true));
    final photo = File('${directory.path}/photo.jpg')
      ..writeAsStringSync('photo');
    final movie = File('${directory.path}/movie.mp4')
      ..writeAsStringSync('movie');
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
    await tester.pumpAndSettle();
    await _dropFiles(tester, [photo.path, movie.path], backend);
    await _pumpAsyncWork(tester);
    await tester.tap(find.byKey(const ValueKey('organization-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('virtual-folder-name-field')),
      '精選',
    );
    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();
    await _dragTo(
      tester,
      find.byKey(const ValueKey('organization-item-0')),
      find.byKey(const ValueKey('organization-folder-0')),
    );
    await _pumpAsyncWork(tester);

    expect(find.text('圖片 0'), findsOneWidget);
    expect(find.text('影片 1'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('organization-classify-all')));
    await _pumpAsyncWork(tester);

    expect(backend.organizationPreviewRequests.last.folderNames, ['精選', '影片']);
    expect(backend.organizationPreviewRequests.last.destinationFolderIds, [
      'organization-folder-0',
      'organization-folder-1',
    ]);
    expect(photo.existsSync(), isTrue);
    expect(movie.existsSync(), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('confirms and applies a same-volume organization plan', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-apply-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/photo.jpg')
      ..writeAsStringSync('original');
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);
    await tester.tap(find.byKey(const ValueKey('organization-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('virtual-folder-name-field')),
      '圖片',
    );
    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();
    await _dragTo(
      tester,
      find.byKey(const ValueKey('organization-item-0')),
      find.byKey(const ValueKey('organization-folder-0')),
    );
    await tester.pumpAndSettle();

    final applyButton = find.byKey(const ValueKey('apply-organization'));
    expect(tester.widget<FilledButton>(applyButton).onPressed, isNotNull);
    await tester.tap(applyButton);
    await tester.pumpAndSettle();
    expect(find.text('套用檔案整理？'), findsOneWidget);
    expect(find.textContaining('建立 1 個資料夾並移動 1 個檔案'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-organization-apply')));
    await tester.pumpAndSettle();

    expect(backend.organizationApplyRequests, hasLength(1));
    expect(
      backend.organizationApplyRequests.single.planId,
      'organization-plan-1',
    );
    expect(find.text('已安全建立 1 個資料夾並移動 1 個檔案'), findsOneWidget);
    expect(find.text('加入檔案，開始規劃資料夾'), findsOneWidget);

    final undoButton = find.byTooltip('復原上一批');
    expect(undoButton, findsOneWidget);
    await tester.tap(undoButton);
    await tester.pumpAndSettle();
    expect(find.text('復原上一批整理？'), findsOneWidget);
    expect(find.textContaining('將把 1 個檔案移回原位'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-organization-undo')));
    await tester.pumpAndSettle();
    expect(backend.organizationUndoRequests, hasLength(1));
    expect(
      backend.organizationUndoRequests.single.batchId,
      'organization-batch-1',
    );
    expect(find.text('已復原 1 個檔案並移除 1 個空資料夾'), findsOneWidget);
    expect(file.readAsStringSync(), 'original');
    expect(tester.takeException(), isNull);
  });

  testWidgets('keeps cross-volume organization apply disabled', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-cross-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final file = File('${directory.path}/photo.jpg')
      ..writeAsStringSync('original');
    final backend = FakeBackend()..organizationCrossVolume = true;

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('workspace-mode-organize')));
    await tester.pumpAndSettle();
    await _dropFile(tester, file.path, backend);
    await _pumpAsyncWork(tester);
    await tester.tap(find.byKey(const ValueKey('organization-new-folder')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('virtual-folder-name-field')),
      '圖片',
    );
    await tester.tap(find.text('建立'));
    await tester.pumpAndSettle();
    await _dragTo(
      tester,
      find.byKey(const ValueKey('organization-item-0')),
      find.byKey(const ValueKey('organization-folder-0')),
    );
    await _pumpAsyncWork(tester);

    expect(backend.organizationPreviewRequests.last.destinationFolderIds, [
      'organization-folder-0',
    ]);
    expect(backend.lastOrganizationPlan?.crossVolumeCount, 1);
    expect(find.text('1 跨磁碟'), findsOneWidget);
    final applyButton = find.byKey(const ValueKey('apply-organization'));
    expect(tester.widget<FilledButton>(applyButton).onPressed, isNull);
    expect(backend.organizationApplyRequests, isEmpty);
    expect(file.readAsStringSync(), 'original');
    expect(tester.takeException(), isNull);
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

  testWidgets('exports and loads a versioned rule recipe file', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final originalSelector = FileSelectorPlatform.instance;
    final selector = FakeFileSelector();
    FileSelectorPlatform.instance = selector;
    addTearDown(() => FileSelectorPlatform.instance = originalSelector);
    final directory = Directory.systemTemp.createTempSync('flick-recipe-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final recipeFile = File('${directory.path}/holiday.flickrecipe');
    selector.saveLocationResult = FileSaveLocation(recipeFile.path);

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();
    final ruleField = find.byType(TextFormField).first;
    await tester.enterText(ruleField, 'holiday-{n}');
    await tester.pump();

    await tester.tap(find.byKey(const ValueKey('rule-recipe-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('save-rule-recipe')));
    await tester.pumpAndSettle();

    expect(recipeFile.existsSync(), isTrue);
    final exported = jsonDecode(recipeFile.readAsStringSync()) as Map;
    expect(exported['kind'], ruleRecipeFileKind);
    expect(exported['schemaVersion'], currentRuleRecipeSchemaVersion);
    final exportedRecipe = decodeRuleRecipeFile(
      recipeFile.readAsStringSync(),
      instanceId: 'widget-test',
    );
    expect(exportedRecipe.rules.single.value, 'holiday-{n}');

    await tester.enterText(ruleField, 'changed-{n}');
    await tester.pump();
    selector.openFileResult = XFile(recipeFile.path);
    await tester.tap(find.byKey(const ValueKey('rule-recipe-menu')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('load-rule-recipe')));
    await tester.pumpAndSettle();
    expect(find.text('取代目前的規則？'), findsOneWidget);
    expect(find.textContaining('命名預設不會變更'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('confirm-load-rule-recipe')));
    await tester.pumpAndSettle();

    final restoredField = find.byType(TextFormField).first;
    final restoredEditor = tester.widget<EditableText>(
      find.descendant(of: restoredField, matching: find.byType(EditableText)),
    );
    expect(restoredEditor.controller.text, 'holiday-{n}');
    expect(find.text('已從 holiday.flickrecipe 載入 1 個規則'), findsOneWidget);
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
    addTearDown(() => _deleteTestDirectory(directory));
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
    selector
      ..openFileResult = null
      ..saveLocationResult = null;
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
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

  testWidgets('previews and remembers safe append-number collisions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final directory = Directory.systemTemp.createTempSync('flick-collision-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final files = ['one.txt', 'two.txt']
        .map((name) => File('${directory.path}/$name')..writeAsStringSync(name))
        .toList(growable: false);
    final backend = FakeBackend();

    await tester.pumpWidget(FlickApp(connector: () async => backend));
    await tester.pumpAndSettle();
    await tester.tap(find.text('檔案預覽'));
    await tester.pumpAndSettle();
    await _dropFiles(
      tester,
      files.map((file) => file.path).toList(growable: false),
      backend,
    );
    await _pumpAsyncWork(tester);

    expect(backend.lastPreviewRequest?.collisionStrategy, 'fail');
    expect(find.text('發現衝突時阻止'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('collision-strategy')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('自動附加流水號').last);
    await _pumpAsyncWork(tester);

    expect(backend.lastPreviewRequest?.collisionStrategy, 'appendNumber');
    expect(find.text('final (2).txt'), findsOneWidget);
    expect(
      find.byKey(ValueKey('collision-resolved-${files[1].path}')),
      findsOneWidget,
    );
    expect(find.text('已避開衝突'), findsOneWidget);
    expect(
      await SharedPreferencesAsync().getString('flick.collision-strategy.v1'),
      'appendNumber',
    );
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

Future<void> _dragTo(WidgetTester tester, Finder source, Finder target) {
  return tester.timedDrag(
    source,
    tester.getCenter(target) - tester.getCenter(source),
    const Duration(milliseconds: 500),
  );
}

Future<void> _deleteTestDirectory(Directory directory) async {
  for (var attempt = 0; attempt < 10; attempt++) {
    if (!directory.existsSync()) return;
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      if (attempt == 9) rethrow;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
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
