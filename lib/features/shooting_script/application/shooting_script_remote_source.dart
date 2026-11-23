import 'dart:async';

import '../../remote_access/domain/remote_shooting_workflow_models.dart';
import '../../replicate/application/replicate_controller.dart';
import '../../replicate/domain/replicate_models.dart';
import '../../video_analysis/domain/video_analysis_models.dart';
import 'script_analysis_controller.dart';
import 'script_asset_binding_controller.dart';

class ShootingScriptRemoteSource implements RemoteShootingWorkflowSource {
  ShootingScriptRemoteSource({
    required ReplicateController replicateController,
    required ShootingScriptAnalysisController analysisController,
    required ShootingScriptAssetBindingController assetBindingController,
  }) : _replicateController = replicateController,
       _analysisController = analysisController,
       _assetBindingController = assetBindingController {
    _replicateController.addListener(_handleChanged);
    _analysisController.addListener(_handleChanged);
    _assetBindingController.addListener(_handleChanged);
  }

  final ReplicateController _replicateController;
  final ShootingScriptAnalysisController _analysisController;
  final ShootingScriptAssetBindingController _assetBindingController;
  final StreamController<String> _changes = StreamController<String>.broadcast(
    sync: true,
  );
  bool _disposed = false;

  @override
  Stream<String> get changes => _changes.stream;

  @override
  RemoteShootingWorkflowRecord? workflowFor(String scriptId) {
    if (!_selectScript(scriptId)) return null;
    final replicate = _replicateController.value;
    final run = replicate.run;
    if (run == null) return null;
    final binding = _assetBindingController.value;
    final analysis = _analysisController.value;
    final assets = <String, RemoteShootingWorkflowAssetRecord>{
      for (final asset in replicate.assets)
        asset.id: RemoteShootingWorkflowAssetRecord(
          id: asset.id,
          name: asset.name,
          type: asset.type.name,
          description: asset.description,
          referenceNumber: asset.referenceNumber,
          localPath: asset.path,
        ),
      for (final asset in binding.assets)
        asset.id: RemoteShootingWorkflowAssetRecord(
          id: asset.id,
          name: asset.name,
          type: asset.type.name,
          description: asset.description,
          referenceNumber: asset.referenceNumber,
          localPath: asset.path,
        ),
    };
    return RemoteShootingWorkflowRecord(
      scriptId: scriptId,
      currentStep: run.currentStep.name,
      confirmShotsStatus: run.confirmShotsStatus.name,
      prepareAssetsStatus: run.prepareAssetsStatus.name,
      composePromptsStatus: run.composePromptsStatus.name,
      shotCount: replicate.shots.length,
      confirmedShotCount: run.confirmedShotIds
          .where((id) => replicate.shots.any((shot) => shot.id == id))
          .length,
      promptCount: replicate.prompts.length,
      analysisCompletedCount: analysis.completedCount,
      analysisFailedCount: analysis.failedCount,
      analysisTotalCount: analysis.totalCount,
      isBusy:
          replicate.isBusy ||
          analysis.isBusy ||
          _assetBindingController.value.isBusy,
      message: _firstText([
        _assetBindingController.value.message,
        analysis.message,
        replicate.message,
      ]),
      errorMessage: _firstText([
        _assetBindingController.value.errorMessage,
        analysis.errorMessage,
        replicate.errorMessage,
      ]),
      assets: assets.values.toList(growable: false),
      links: binding.links
          .map(
            (link) => RemoteShootingWorkflowLinkRecord(
              shotId: link.shotId,
              assetId: link.scriptAssetId,
              matchSource: link.matchSource.name,
              confidence: link.confidence,
              matchReason: link.matchReason,
              confirmed: link.confirmed,
              locked: link.locked,
            ),
          )
          .toList(growable: false),
      replicas: replicate.replicatedImages
          .map(
            (image) => RemoteShootingWorkflowReplicaRecord(
              shotId: image.scriptShotId,
              status: image.status.name,
              errorMessage: image.errorMessage,
              localPath: image.generatedFramePath,
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  void confirmShots(String scriptId) {
    if (!_selectScript(scriptId)) throw StateError('拍摄脚本不存在');
    _replicateController.confirmAllShots();
    _replicateController.moveToStep(ReplicateStep.confirmShots);
  }

  @override
  Future<void> matchAssets(String scriptId) async {
    if (!_selectScript(scriptId)) throw StateError('拍摄脚本不存在');
    _replicateController.moveToStep(ReplicateStep.prepareAssets);
    await _assetBindingController.autoMatchAll(
      preferredAssets: _replicateController.value.assets,
    );
    final error = _assetBindingController.value.errorMessage.trim();
    if (error.isNotEmpty) throw StateError(error);
  }

  @override
  Future<void> buildScript(String scriptId) async {
    if (!_selectScript(scriptId)) throw StateError('拍摄脚本不存在');
    _replicateController.confirmAllShots();
    _replicateController.clearPromptsBeforeBuild();
    final replicaPaths = <String, String>{
      for (final image in _replicateController.value.replicatedImages)
        if (image.status == ProcessingStatus.completed &&
            image.generatedFramePath.trim().isNotEmpty)
          image.scriptShotId: image.generatedFramePath,
    };
    final completed = await _analysisController.buildScript(
      imagePathOverrides: replicaPaths,
    );
    if (!completed) {
      throw StateError(
        _analysisController.value.errorMessage.trim().isEmpty
            ? '脚本构建未完成'
            : _analysisController.value.errorMessage,
      );
    }
    await _replicateController.composeAllPrompts(navigateToComposeStep: false);
    final error = _replicateController.value.errorMessage.trim();
    if (error.isNotEmpty) throw StateError(error);
  }

  @override
  Future<void> replicateStoryboards(String scriptId, {String? shotId}) async {
    if (!_selectScript(scriptId)) throw StateError('拍摄脚本不存在');
    if (shotId == null) {
      await _replicateController.replicateAllShots();
    } else {
      final succeeded = await _replicateController.replicateShot(shotId);
      if (!succeeded) {
        throw StateError(
          _replicateController.value.errorMessage.trim().isEmpty
              ? '复刻分镜失败'
              : _replicateController.value.errorMessage,
        );
      }
    }
    final error = _replicateController.value.errorMessage.trim();
    if (error.isNotEmpty) throw StateError(error);
  }

  @override
  void cancelMatching() => _assetBindingController.cancelMatching();

  @override
  void cancelBuild() => _analysisController.cancel();

  bool _selectScript(String scriptId) {
    if (!_replicateController.value.scripts.any(
      (script) => script.id == scriptId,
    )) {
      return false;
    }
    if (_replicateController.value.selectedScriptId != scriptId) {
      _replicateController.selectScript(scriptId);
    }
    return true;
  }

  void _handleChanged() {
    if (_disposed) return;
    final scriptId = _replicateController.value.selectedScriptId;
    if (scriptId.isNotEmpty) _changes.add(scriptId);
  }

  static String _firstText(Iterable<String> values) {
    for (final value in values) {
      if (value.trim().isNotEmpty) return value.trim();
    }
    return '';
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _replicateController.removeListener(_handleChanged);
    _analysisController.removeListener(_handleChanged);
    _assetBindingController.removeListener(_handleChanged);
    unawaited(_changes.close());
  }
}
