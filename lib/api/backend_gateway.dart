import 'package:bridra_flutter/bridra_flutter.dart';

import 'generated/bridra_api.g.dart';

export 'generated/bridra_api.g.dart';

abstract interface class BackendGateway implements BridraApi {
  Stream<List<int>> download(
    RpcFileReference file, {
    Duration timeout = const Duration(minutes: 15),
    RpcCancellationToken? cancellationToken,
    int maxAttempts = 3,
  });

  Future<RpcFileReference> upload(
    RpcFileUpload file, {
    Duration timeout = const Duration(minutes: 15),
    RpcCancellationToken? cancellationToken,
    int maxAttempts = 3,
  });

  Future<void> close();
}

class RpcBackend implements BackendGateway {
  RpcBackend._(this._client) : _api = BridraRpcApi(_client);

  final RpcClient _client;
  final BridraRpcApi _api;
  late final HealthInfo _health;

  static Future<RpcBackend> connect() async {
    final client = await connectDefaultRpcClient();
    final backend = RpcBackend._(client);
    try {
      backend._health = await backend._api.health();
      if (backend._health.protocolVersion != supportedBackendProtocolVersion) {
        throw BackendProtocolException(
          'Unsupported backend protocol '
          '${backend._health.protocolVersion}; '
          'expected $supportedBackendProtocolVersion.',
        );
      }
      return backend;
    } on Object {
      await client.close();
      rethrow;
    }
  }

  @override
  Future<HealthInfo> health({RpcCancellationToken? cancellationToken}) async {
    if (cancellationToken?.isCancelled ?? false) {
      throw const RpcCancelledException(BridraMethods.systemHealth);
    }
    return _health;
  }

  @override
  Future<DirectoryScanResult> scanDirectories(
    ScanDirectoriesRequest request, {
    RpcCancellationToken? cancellationToken,
  }) {
    return _api.scanDirectories(request, cancellationToken: cancellationToken);
  }

  @override
  Future<OrganizationPlan> previewOrganization(
    PreviewOrganizationRequest request, {
    RpcCancellationToken? cancellationToken,
  }) {
    return _api.previewOrganization(
      request,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Future<ApplyOrganizationResult> applyOrganization(
    ApplyOrganizationRequest request, {
    RpcCancellationToken? cancellationToken,
  }) {
    return _api.applyOrganization(
      request,
      cancellationToken: cancellationToken,
    );
  }

  @override
  Future<RenamePlan> previewRename(
    PreviewRenameRequest request, {
    RpcCancellationToken? cancellationToken,
  }) {
    return _api.previewRename(request, cancellationToken: cancellationToken);
  }

  @override
  Future<ApplyRenameResult> applyRename(
    ApplyRenameRequest request, {
    RpcCancellationToken? cancellationToken,
  }) {
    return _api.applyRename(request, cancellationToken: cancellationToken);
  }

  @override
  Future<UndoRenameResult> undoRename(
    UndoRenameRequest request, {
    RpcCancellationToken? cancellationToken,
  }) {
    return _api.undoRename(request, cancellationToken: cancellationToken);
  }

  @override
  Future<RenameHistory> renameHistory({
    RpcCancellationToken? cancellationToken,
  }) {
    return _api.renameHistory(cancellationToken: cancellationToken);
  }

  @override
  Stream<List<int>> download(
    RpcFileReference file, {
    Duration timeout = const Duration(minutes: 15),
    RpcCancellationToken? cancellationToken,
    int maxAttempts = 3,
  }) {
    return _client.download(
      file,
      timeout: timeout,
      cancellationToken: cancellationToken,
      maxAttempts: maxAttempts,
    );
  }

  @override
  Future<RpcFileReference> upload(
    RpcFileUpload file, {
    Duration timeout = const Duration(minutes: 15),
    RpcCancellationToken? cancellationToken,
    int maxAttempts = 3,
  }) {
    return _client.upload(
      file,
      timeout: timeout,
      cancellationToken: cancellationToken,
      maxAttempts: maxAttempts,
    );
  }

  @override
  Future<void> close() => _client.close();
}
