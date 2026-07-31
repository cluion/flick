import 'package:bridra_flutter/bridra_flutter.dart';
import 'package:flick/api/backend_gateway.dart';
import 'package:flick/app/flick_app.dart';
import 'package:flutter/material.dart' show Size;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class FakeBackend implements BackendGateway {
  @override
  Future<void> close() async {}

  @override
  Future<HealthInfo> health({RpcCancellationToken? cancellationToken}) async {
    return const HealthInfo(
      status: 'ok',
      frameworkVersion: '0.8.0',
      protocolVersion: 1,
      runtime: 'Go sidecar',
      architecture: 'Middleware -> Controller -> Service',
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
    return RenamePlan(
      planId: 'plan-1',
      sourcePaths: request.paths,
      originalNames: const ['draft.txt'],
      proposedNames: const ['final.txt'],
      targetPaths: const ['/tmp/final.txt'],
      statuses: const ['ready'],
      messages: const [''],
      renameableCount: 1,
      unchangedCount: 0,
      errorCount: 0,
    );
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

    await tester.pumpWidget(FlickApp(connector: () async => FakeBackend()));
    await tester.pumpAndSettle();

    expect(find.text('Flick'), findsOneWidget);
    expect(find.text('本機引擎就緒'), findsOneWidget);
    expect(find.text('改名規則'), findsOneWidget);
    expect(find.text('1. 設定新檔名'), findsOneWidget);
    expect(find.text('拖放檔案到這裡'), findsOneWidget);
    expect(find.text('開始批次改名'), findsOneWidget);
  });
}
