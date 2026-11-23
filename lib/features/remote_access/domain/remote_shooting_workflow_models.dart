class RemoteShootingWorkflowAssetRecord {
  const RemoteShootingWorkflowAssetRecord({
    required this.id,
    required this.name,
    required this.type,
    required this.description,
    required this.referenceNumber,
    required this.localPath,
  });

  final String id;
  final String name;
  final String type;
  final String description;
  final int referenceNumber;

  /// 仅供桌面媒体白名单注册，禁止直接序列化。
  final String localPath;
}

class RemoteShootingWorkflowLinkRecord {
  const RemoteShootingWorkflowLinkRecord({
    required this.shotId,
    required this.assetId,
    required this.matchSource,
    required this.confidence,
    required this.matchReason,
    required this.confirmed,
    required this.locked,
  });

  final String shotId;
  final String assetId;
  final String matchSource;
  final double confidence;
  final String matchReason;
  final bool confirmed;
  final bool locked;
}

class RemoteShootingWorkflowReplicaRecord {
  const RemoteShootingWorkflowReplicaRecord({
    required this.shotId,
    required this.status,
    required this.errorMessage,
    required this.localPath,
  });

  final String shotId;
  final String status;
  final String errorMessage;

  /// 仅供桌面媒体白名单注册，禁止直接序列化。
  final String localPath;
}

class RemoteShootingWorkflowRecord {
  const RemoteShootingWorkflowRecord({
    required this.scriptId,
    required this.currentStep,
    required this.confirmShotsStatus,
    required this.prepareAssetsStatus,
    required this.composePromptsStatus,
    required this.shotCount,
    required this.confirmedShotCount,
    required this.promptCount,
    required this.analysisCompletedCount,
    required this.analysisFailedCount,
    required this.analysisTotalCount,
    required this.isBusy,
    required this.message,
    required this.errorMessage,
    required this.assets,
    required this.links,
    required this.replicas,
  });

  final String scriptId;
  final String currentStep;
  final String confirmShotsStatus;
  final String prepareAssetsStatus;
  final String composePromptsStatus;
  final int shotCount;
  final int confirmedShotCount;
  final int promptCount;
  final int analysisCompletedCount;
  final int analysisFailedCount;
  final int analysisTotalCount;
  final bool isBusy;
  final String message;
  final String errorMessage;
  final List<RemoteShootingWorkflowAssetRecord> assets;
  final List<RemoteShootingWorkflowLinkRecord> links;
  final List<RemoteShootingWorkflowReplicaRecord> replicas;
}

abstract interface class RemoteShootingWorkflowSource {
  Stream<String> get changes;

  RemoteShootingWorkflowRecord? workflowFor(String scriptId);
  void confirmShots(String scriptId);
  Future<void> matchAssets(String scriptId);
  Future<void> buildScript(String scriptId);
  Future<void> replicateStoryboards(String scriptId, {String? shotId});
  void cancelMatching();
  void cancelBuild();
}
